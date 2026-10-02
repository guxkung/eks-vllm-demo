# Raw terraform-aws-modules/eks clusters don't ship a default StorageClass.
# The aws-ebs-csi-driver addon (eks.tf) only installs the controller; it
# doesn't create one for you. Without this, every PVC in the cluster
# (LiteLLM's bundled Postgres, Prometheus, anything else) stays Pending
# forever waiting for a default class to bind against.
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [module.eks]
}
