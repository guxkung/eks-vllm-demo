# IAM role (pod identity), node IAM role/instance profile, and the SQS
# interruption queue Karpenter needs -- all via the community submodule so
# we don't hand-roll the policy JSON.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name

  create_pod_identity_association = true
  enable_inline_policy             = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version
  wait       = true
  timeout    = 600

  values = [
    yamlencode({
      settings = {
        clusterName       = module.eks.cluster_name
        clusterEndpoint   = module.eks.cluster_endpoint
        interruptionQueue = module.karpenter.queue_name
      }
      serviceAccount = {
        name = "karpenter"
        # No IRSA annotation needed -- the pod identity association above
        # binds this service account to module.karpenter.iam_role_arn.
      }
      controller = {
        resources = {
          requests = { cpu = "1", memory = "1Gi" }
          limits   = { memory = "1Gi" }
        }
      }
    })
  ]

  depends_on = [module.eks, module.karpenter]
}

# ---------- Default (non-GPU) NodePool: KEDA/Prometheus/LiteLLM overflow ----------
resource "kubectl_manifest" "ec2nodeclass_default" {
  depends_on = [helm_release.karpenter]

  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiFamily: AL2023
      amiSelectorTerms:
        - alias: al2023@latest
      role: ${module.karpenter.node_iam_role_name}
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}
      tags:
        karpenter.sh/discovery: ${module.eks.cluster_name}
  YAML
}

resource "kubectl_manifest" "nodepool_default" {
  depends_on = [kubectl_manifest.ec2nodeclass_default]

  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: default
    spec:
      template:
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          requirements:
            - key: karpenter.k8s.aws/instance-family
              operator: In
              values: ${jsonencode(var.karpenter_default_instance_types)}
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["on-demand"]
      limits:
        cpu: 200
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 5m
  YAML
}

# ---------- GPU NodePool: vLLM ----------
resource "kubectl_manifest" "ec2nodeclass_gpu" {
  depends_on = [helm_release.karpenter]

  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: gpu
    spec:
      amiFamily: AL2023
      amiSelectorTerms:
        - alias: al2023@latest
      role: ${module.karpenter.node_iam_role_name}
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 200Gi
            volumeType: gp3
            deleteOnTermination: true
      tags:
        karpenter.sh/discovery: ${module.eks.cluster_name}
        workload: gpu
  YAML
}

# Terraform has no resource representing the EC2 instances Karpenter
# launches -- they're created dynamically via NodeClaims, not by any
# Terraform-managed aws_instance. If terraform destroy tears down the
# Karpenter controller (or the cluster) before those instances are
# terminated, they're orphaned: still attached to the VPC's subnets via
# ENI, which then blocks subnet/VPC deletion indefinitely.
#
# This resource's destroy-time provisioner runs BEFORE the EKS/VPC
# teardown (because it depends_on the NodePools/EC2NodeClasses/controller,
# Terraform destroys it first, while the cluster is still reachable). It
# first asks Karpenter to drain and terminate its own nodes gracefully,
# then force-terminates anything left over directly via the EC2 API as a
# fallback, so destroy never hangs on a leftover ENI.
resource "null_resource" "karpenter_node_cleanup" {
  depends_on = [
    kubectl_manifest.nodepool_default,
    kubectl_manifest.nodepool_gpu,
    kubectl_manifest.ec2nodeclass_default,
    kubectl_manifest.ec2nodeclass_gpu,
    helm_release.karpenter,
  ]

  triggers = {
    cluster_name = module.eks.cluster_name
    region       = var.region
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      set -u
      aws eks update-kubeconfig --name "${self.triggers.cluster_name}" --region "${self.triggers.region}" || true

      # Graceful path: deleting the NodePools/EC2NodeClasses triggers
      # Karpenter's own termination finalizers, which drain pods and call
      # EC2 TerminateInstances before releasing each node object.
      kubectl delete nodepool --all --wait=true --timeout=10m || true
      kubectl delete ec2nodeclass --all --wait=true --timeout=5m || true

      # Hard fallback: force-terminate anything still tagged for this
      # cluster (e.g. a pod that never evicted, or the controller already
      # gone) so a leftover ENI can never block subnet/VPC deletion.
      IDS=$(aws ec2 describe-instances \
        --filters "Name=tag:karpenter.sh/discovery,Values=${self.triggers.cluster_name}" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --region "${self.triggers.region}" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo "")
      if [ -n "$IDS" ]; then
        aws ec2 terminate-instances --region "${self.triggers.region}" --instance-ids $IDS || true
        aws ec2 wait instance-terminated --region "${self.triggers.region}" --instance-ids $IDS || true
      fi
    EOT
  }
}

resource "kubectl_manifest" "nodepool_gpu" {
  depends_on = [kubectl_manifest.ec2nodeclass_gpu]

  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: gpu
    spec:
      template:
        metadata:
          labels:
            workload: gpu
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: gpu
          taints:
            - key: nvidia.com/gpu
              value: "true"
              effect: NoSchedule
          requirements:
            - key: node.kubernetes.io/instance-type
              operator: In
              values: ${jsonencode(var.vllm_instance_types)}
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["${var.vllm_capacity_type}"]
            - key: workload
              operator: In
              values: ["gpu"]
      limits:
        cpu: 400
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 10m
  YAML
}
