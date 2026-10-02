module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access = true

  # Lets the identity running `terraform apply` administer the cluster via
  # an access entry, instead of hand-editing aws-auth.
  enable_cluster_creator_admin_permissions = true

  # Karpenter's EC2NodeClass securityGroupSelectorTerms looks for a security
  # group carrying this tag. vpc.tf only tags subnets -- nothing tags a
  # security group unless we do it here, which is why EC2NodeClass/NodePool
  # were stuck NotReady with zero security groups resolved.
  node_security_group_tags = merge(local.tags, {
    "karpenter.sh/discovery" = var.name
  })

  # Pod Identity is the modern replacement for IRSA -- the Karpenter module
  # below uses it, so the add-on agent must be installed.
  #
  # IMPORTANT: vpc-cni and eks-pod-identity-agent are marked before_compute.
  # Without that, Terraform has no ordering guarantee between the node group
  # and these add-ons -- nodes can join before CNI is actually ready, which
  # leaves every pod scheduled on them (including CoreDNS and the Karpenter
  # controller itself) stuck in ContainerCreating with NetworkPluginNotReady.
  # before_compute forces the module to create these first and makes the
  # node group depend on them.
  addons = {
    vpc-cni = {
      before_compute = true
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
    coredns   = {}
    kube-proxy = {}

    # Needs IAM permissions (CreateVolume/AttachVolume/etc) to do anything.
    # Without a pod-identity association, the controller's ebs-plugin
    # container has no AWS credentials and crashes on startup
    # (pod status: Error / CrashLoopBackOff).
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  # Small, always-on node group for cluster-critical / non-GPU workloads:
  # CoreDNS, Karpenter controller, KEDA, Prometheus, LiteLLM. Karpenter
  # takes over provisioning everything else (default + GPU NodePools).
  eks_managed_node_groups = {
    system = {
      instance_types = var.system_node_instance_types
      min_size       = 1
      max_size       = var.system_node_desired_size + 2
      desired_size   = var.system_node_desired_size

      labels = {
        role = "system"
      }
    }
  }

  tags = local.tags
}

# ---------- EBS CSI driver IAM (pod identity) ----------
data "aws_iam_policy_document" "ebs_csi_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.name}-ebs-csi-driver"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_trust.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
