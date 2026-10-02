output "configure_kubectl" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "vllm_internal_endpoint" {
  value = "http://${kubernetes_service_v1.vllm.metadata[0].name}.${kubernetes_namespace.llm.metadata[0].name}.svc.cluster.local:8000/v1"
}

output "litellm_internal_endpoint" {
  value = "http://litellm.${kubernetes_namespace.llm.metadata[0].name}.svc.cluster.local:4000"
}

output "litellm_master_key" {
  value     = local.litellm_master_key
  sensitive = true
}

output "karpenter_node_role_name" {
  value = module.karpenter.node_iam_role_name
}
