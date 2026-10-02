resource "random_password" "litellm_master_key" {
  count   = var.litellm_master_key == "" ? 1 : 0
  length  = 32
  special = false
}

# The chart's own README explicitly warns the bundled Postgres's default
# auth.password/postgres-password ("NoTaGrEaTpAsSwOrD") must not be used.
resource "random_password" "litellm_db_password" {
  length  = 24
  special = false
}

resource "random_password" "litellm_db_admin_password" {
  length  = 24
  special = false
}

locals {
  litellm_master_key = var.litellm_master_key != "" ? var.litellm_master_key : "sk-${random_password.litellm_master_key[0].result}"
}

resource "helm_release" "litellm" {
  name      = "litellm"
  namespace = kubernetes_namespace.llm.metadata[0].name

  # The chart is published as an OCI artifact, not a classic index.yaml
  # repo (the old https://berriai.github.io/litellm repo 404s -- it's not
  # how this chart is distributed). Versioning also now tracks LiteLLM's
  # own release numbers (currently v1.9x), not the old pre-migration 0.x
  # scheme, so we deliberately leave `version` unset to resolve whatever
  # is newest rather than pin to a number that'll go stale again.
  repository = "oci://ghcr.io/berriai"
  chart      = "litellm-helm"
  version    = var.litellm_chart_version != "" ? var.litellm_chart_version : null
  wait       = true
  timeout    = 300

  depends_on = [kubernetes_service_v1.vllm]

  values = [
    yamlencode({
      replicaCount = var.litellm_replicas
      masterkey    = local.litellm_master_key

      # The chart's default image (ghcr.io/berriai/litellm) is the
      # stateless variant and never runs Prisma's schema migration on
      # startup -- it assumes no database at all. Since db.deployStandalone
      # bundles a real Postgres below, we need the -database variant,
      # which runs that migration on boot and actually creates the
      # LiteLLM_* tables.
      image = {
        repository = "ghcr.io/berriai/litellm-database"
      }

      # Bundled single-instance Postgres via the chart's built-in Bitnami
      # subchart (chart default is already true -- explicit here for
      # clarity). Fine for this demo; for persistent virtual keys/budgets
      # across restarts/replicas, set db.useExisting and point db.endpoint
      # at an external Postgres (e.g. RDS) instead.
      db = {
        deployStandalone = true
      }
      postgresql = {
        auth = {
          username         = "litellm"
          password         = random_password.litellm_db_password.result
          postgresPassword = random_password.litellm_db_admin_password.result
          database         = "litellm"
        }
        primary = {
          persistence = {
            size         = "8Gi"
            storageClass = kubernetes_storage_class_v1.gp3.metadata[0].name
          }
        }
      }

      proxy_config = {
        model_list = [
          {
            model_name = var.vllm_served_model_name
            litellm_params = {
              model    = "openai/${var.vllm_served_model_name}"
              api_base = "http://${kubernetes_service_v1.vllm.metadata[0].name}.${kubernetes_namespace.llm.metadata[0].name}.svc.cluster.local:8000/v1"
              api_key  = "not-needed"
            }
          }
        ]
      }

      service = {
        type = "ClusterIP"
        port = 4000
      }

      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { cpu = "1", memory = "1Gi" }
      }
    })
  ]
}
