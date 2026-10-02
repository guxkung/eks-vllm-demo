resource "helm_release" "keda" {
  name             = "keda"
  namespace        = "keda"
  create_namespace = true
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = var.keda_version
  wait             = true
  timeout          = 300

  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "keda-operator"
  }
  depends_on = [ module.eks, aws_iam_role.keda_operator_role ]
}

# KEDA Operator Role
resource "aws_iam_role" "keda_operator_role" {
  name = "keda-operator"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })
}

# Create the IAM policy with the SQS permissions
resource "aws_iam_policy" "keda_operator_policy" {
  name        = "keda-operator-perms"
  description = "Policy that allows the keda operator to read SQS queues"
  
  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "AmazonSQSReadOnlyAccess",
        "Effect": "Allow",
        "Action": [
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ListDeadLetterSourceQueues",
          "sqs:ListQueues",
          "sqs:ListMessageMoveTasks",
          "sqs:ListQueueTags",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        "Resource": "*"
      }
    ]
  })
}

# Attach the policy to the KEDA operator role
resource "aws_iam_role_policy_attachment" "keda_sqs_policy_attachment" {
  role       = aws_iam_role.keda_operator_role.name
  policy_arn = aws_iam_policy.keda_operator_policy.arn
}

# Associate KEDA Operator role with the KEDA Operator service account
resource "aws_eks_pod_identity_association" "keda_operator" {
  cluster_name    = var.name
  namespace       = "keda"
  service_account = "keda-operator"
  role_arn        = aws_iam_role.keda_operator_role.arn
  depends_on = [
    helm_release.keda
  ]
}

# DaemonSet that advertises nvidia.com/gpu on GPU nodes so the scheduler
# and vLLM's resource requests/limits can see it. Tolerates the taint
# Karpenter's GPU NodePool applies.
resource "helm_release" "nvidia_device_plugin" {
  name             = "nvidia-device-plugin"
  namespace        = "kube-system"
  repository       = "https://nvidia.github.io/k8s-device-plugin"
  chart            = "nvidia-device-plugin"
  version          = var.nvidia_device_plugin_version
  wait             = true
  timeout          = 300

  values = [
    yamlencode({
      nodeSelector = { workload = "gpu" }
      tolerations = [
        {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }
      ]
    })
  ]

  depends_on = [module.eks]
}

# Minimal Prometheus so the KEDA ScaledObject in vllm.tf has a queue-depth
# metric to query. Set enable_prometheus = false if you already run one.
resource "helm_release" "kube_prometheus_stack" {
  count = var.enable_prometheus ? 1 : 0

  name             = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.kube_prometheus_stack_version
  wait             = true
  timeout          = 600

  values = [
    yamlencode({
      # Keep this demo-sized: skip node-exporter/kube-state-metrics/Grafana
      # dashboards you don't need for the vLLM queue-depth scaler.
      grafana           = { enabled = false }
      alertmanager      = { enabled = false }
      nodeExporter      = { enabled = false }
      kubeStateMetrics  = { enabled = true }

      prometheus = {
        prometheusSpec = {
          retention             = "6h"
          serviceMonitorSelectorNilUsesHelmValues = false
          podMonitorSelectorNilUsesHelmValues     = false
          resources = {
            requests = { cpu = "250m", memory = "512Mi" }
            limits   = { memory = "1Gi" }
          }
        }
      }
    })
  ]

  depends_on = [module.eks]
}

# Scrapes vLLM's /metrics endpoint into Prometheus.
resource "kubectl_manifest" "vllm_podmonitor" {
  count      = var.enable_prometheus ? 1 : 0
  depends_on = [helm_release.kube_prometheus_stack, kubernetes_service_v1.vllm]

  yaml_body = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: PodMonitor
    metadata:
      name: vllm
      namespace: ${kubernetes_namespace.llm.metadata[0].name}
    spec:
      selector:
        matchLabels:
          app: vllm
      podMetricsEndpoints:
        - port: http
          path: /metrics
          interval: 15s
  YAML
}
