resource "kubernetes_namespace" "llm" {
  metadata {
    name = "llm"
  }
}

resource "kubernetes_secret" "hf_token" {
  metadata {
    name      = "hf-token"
    namespace = kubernetes_namespace.llm.metadata[0].name
  }
  data = {
    token = var.hf_token
  }
}

locals {
  vllm_image = var.vllm_use_gpu ? "${var.vllm_image_repository}:${var.vllm_image_tag}" : "${var.vllm_cpu_image_repository}:${var.vllm_cpu_image_tag}"

  vllm_base_args = [
    "--model", var.vllm_use_gpu ? var.vllm_model_name : var.vllm_cpu_model_name,
    "--served-model-name", var.vllm_served_model_name,
    "--host", "0.0.0.0",
    "--port", "8000",
  ]

  vllm_gpu_args = [
    "--tensor-parallel-size", tostring(var.vllm_tensor_parallel_size),
    "--gpu-memory-utilization", tostring(var.vllm_gpu_memory_utilization),
    "--max-model-len", tostring(var.vllm_max_model_len),
    "--dtype", var.vllm_dtype,
  ]

  vllm_cpu_args = [
    "--max-model-len", tostring(var.vllm_cpu_max_model_len),
    "--dtype", var.vllm_cpu_dtype,
  ]

  vllm_args = concat(
    local.vllm_base_args,
    var.vllm_use_gpu ? local.vllm_gpu_args : local.vllm_cpu_args,
    var.vllm_use_gpu && var.vllm_quantization != "" ? ["--quantization", var.vllm_quantization] : [],
    var.vllm_extra_args,
  )

  vllm_resource_requests = merge(
    { cpu = var.vllm_cpu_request, memory = var.vllm_mem_request },
    var.vllm_use_gpu ? { "nvidia.com/gpu" = tostring(var.vllm_gpu_count) } : {}
  )

  vllm_resource_limits = merge(
    { cpu = var.vllm_cpu_limit, memory = var.vllm_mem_limit },
    var.vllm_use_gpu ? { "nvidia.com/gpu" = tostring(var.vllm_gpu_count) } : {}
  )

  # In-cluster DNS name of the Prometheus this stack installs, when enabled.
  prometheus_address = var.enable_prometheus ? "http://kube-prometheus-stack-prometheus.monitoring.svc:9090" : var.prometheus_server_address
}

resource "kubernetes_deployment_v1" "vllm" {
  metadata {
    name      = "vllm"
    namespace = kubernetes_namespace.llm.metadata[0].name
    labels    = { app = "vllm" }
  }

  # Karpenter's GPU NodePool scales the nodes; KEDA's ScaledObject below
  # drives replica count, so no fixed `replicas` beyond the initial minimum.
  spec {
    replicas = var.vllm_replicas_min

    selector {
      match_labels = { app = "vllm" }
    }

    template {
      metadata {
        labels = { app = "vllm" }
      }

      spec {
        # Kubernetes auto-injects <SERVICE_NAME>_PORT-style env vars for
        # every Service in the namespace. Our Service is named "vllm", so
        # it injects VLLM_PORT=tcp://<cluster-ip>:8000 -- which collides
        # with vLLM's own VLLM_PORT env var (used for its internal engine
        # socket) and crashes it on startup. Disabling service links is
        # the fix vLLM's own docs point to for this exact collision.
        enable_service_links = false

        node_selector = var.vllm_use_gpu ? { workload = "gpu" } : {}

        dynamic "toleration" {
          for_each = var.vllm_use_gpu ? [1] : []
          content {
            key      = "nvidia.com/gpu"
            operator = "Equal"
            value    = "true"
            effect   = "NoSchedule"
          }
        }

        container {
          name  = "vllm"
          image = local.vllm_image
          args  = local.vllm_args

          # CPU-mode images need privileged for CPU-affinity binding
          # (VLLM_CPU_OMP_THREADS_BIND); irrelevant/unused in GPU mode.
          security_context {
            privileged = !var.vllm_use_gpu
          }

          env {
            name = "HUGGING_FACE_HUB_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.hf_token.metadata[0].name
                key  = "token"
              }
            }
          }

          # Only read by the CPU backend; harmless no-op under GPU.
          env {
            name  = "VLLM_CPU_KVCACHE_SPACE"
            value = tostring(var.vllm_cpu_kvcache_space_gb)
          }

          port {
            name           = "http"
            container_port = 8000
          }

          resources {
            requests = local.vllm_resource_requests
            limits   = local.vllm_resource_limits
          }

          volume_mount {
            name       = "shm"
            mount_path = "/dev/shm"
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 60
            period_seconds        = 10
            failure_threshold     = 30
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 120
            period_seconds        = 20
          }
        }

        volume {
          name = "shm"
          empty_dir {
            medium     = "Memory"
            size_limit = var.vllm_shm_size
          }
        }
      }
    }
  }
  depends_on = [kubectl_manifest.nodepool_default, kubectl_manifest.nodepool_gpu]
}

resource "kubernetes_service_v1" "vllm" {
  metadata {
    name      = "vllm"
    namespace = kubernetes_namespace.llm.metadata[0].name
  }
  spec {
    selector = { app = "vllm" }
    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
    type = "ClusterIP"
  }
}

# Scales vLLM replicas on request-queue depth from vLLM's own /metrics
# (vllm:num_requests_waiting), scraped by the PodMonitor in keda.tf.
resource "kubectl_manifest" "vllm_scaledobject" {
  depends_on = [helm_release.keda, kubernetes_deployment_v1.vllm]

  yaml_body = <<-YAML
    apiVersion: keda.sh/v1alpha1
    kind: ScaledObject
    metadata:
      name: vllm-scaledobject
      namespace: ${kubernetes_namespace.llm.metadata[0].name}
    spec:
      scaleTargetRef:
        name: vllm
      minReplicaCount: ${var.vllm_replicas_min}
      maxReplicaCount: ${var.vllm_replicas_max}
      cooldownPeriod: 300
      pollingInterval: 15
      triggers:
        - type: prometheus
          metadata:
            serverAddress: ${local.prometheus_address}
            metricName: vllm_num_requests_waiting
            query: sum(vllm:num_requests_waiting{namespace="${kubernetes_namespace.llm.metadata[0].name}"})
            threshold: "${var.keda_scale_metric_threshold}"
  YAML
}
