# EKS LLM Demo Stack: VPC + EKS + Karpenter + KEDA + vLLM + LiteLLM

Fully self-contained -- one `terraform apply` builds everything from scratch:

| Layer | What |
|---|---|
| Network | New VPC (`terraform-aws-modules/vpc`), private + public subnets across `az_count` AZs, tagged for Karpenter/ELB discovery |
| Cluster | New EKS cluster (`terraform-aws-modules/eks` v21), CoreDNS/kube-proxy/VPC-CNI/EBS-CSI/pod-identity-agent add-ons, one small always-on managed node group for system workloads |
| Autoscaling | Karpenter (pod identity, no IRSA needed) with a cheap `default` NodePool and a tainted `gpu` NodePool (g5/g6) |
| GPU support | NVIDIA device plugin DaemonSet, so pods can request `nvidia.com/gpu` |
| Metrics | Minimal `kube-prometheus-stack` scraping vLLM's `/metrics` |
| Inference | vLLM Deployment in the `llm` namespace, every model/runtime flag exposed as a Terraform variable |
| Scaling | KEDA `ScaledObject` scaling vLLM replicas on `vllm:num_requests_waiting` |
| Gateway | LiteLLM (`litellm-helm` chart), OpenAI-compatible, `model_list` pointed at vLLM |

## Prerequisites

- Terraform >= 1.6, AWS CLI v2 (used for cluster auth via `aws eks get-token`)
- An AWS account with an EC2 quota for the GPU instance family you plan to use
  (`g5`/`g6` on-demand vCPU quota is 0 by default on new accounts -- request
  a Service Quota increase for "Running On-Demand G and VT instances" first,
  or set `vllm_capacity_type = "spot"`)
- Credentials with permission to create VPC/EKS/IAM/EC2 resources

## Usage

```bash
terraform init
terraform apply \
  -var="hf_token=hf_xxx" \
  -var="vllm_model_name=meta-llama/Llama-3.1-8B-Instruct"
```

First apply takes roughly 15-20 minutes: EKS control plane (~10 min) is the
long pole, then Karpenter/KEDA/Prometheus install, then Karpenter launches
the first GPU node and vLLM pulls model weights.

```bash
terraform output configure_kubectl   # then run the printed command
kubectl -n llm get pods -w
```

Call the model through LiteLLM (port-forward for a quick local test):

```bash
kubectl -n llm port-forward svc/litellm 4000:4000
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $(terraform output -raw litellm_master_key)" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama-3.1-8b","messages":[{"role":"user","content":"hi"}]}'
```

## Configuring the model

Every vLLM runtime flag is a variable -- override any of them, e.g.:

```bash
terraform apply \
  -var="vllm_model_name=mistralai/Mistral-7B-Instruct-v0.3" \
  -var="vllm_served_model_name=mistral-7b" \
  -var="vllm_tensor_parallel_size=1" \
  -var="vllm_gpu_count=1" \
  -var="vllm_max_model_len=16384" \
  -var="vllm_quantization=awq" \
  -var='vllm_instance_types=["g5.2xlarge","g6.2xlarge"]' \
  -var="vllm_capacity_type=spot" \
  -var="vllm_replicas_min=1" \
  -var="vllm_replicas_max=6"
```

For a bigger model split across multiple GPUs on one node, raise
`vllm_tensor_parallel_size` and `vllm_gpu_count` together and pick an
instance type with enough GPUs (e.g. `g5.12xlarge` has 4).

## Cost notes for a demo

- `single_nat_gateway = true` (default) uses one shared NAT instead of one
  per AZ.
- The system node group (`system_node_instance_types`, default one `m6i.large`)
  runs 24/7; GPU nodes are Karpenter-managed and scale to zero when `vllm`
  scales down to `vllm_replicas_min` and stay empty long enough
  (`consolidateAfter: 10m` on the `gpu` NodePool).
- Set `vllm_capacity_type = "spot"` to cut GPU cost significantly for
  non-production use.

## Teardown

```bash
terraform destroy
```

Karpenter-provisioned nodes are tied to the NodePool CRs and get cleaned up
automatically as part of destroy; if a `destroy` ever leaves orphaned GPU
instances (e.g. an interrupted apply), check the EC2 console for instances
tagged `karpenter.sh/discovery = <name>`.

## What's intentionally left out

- TLS/ingress in front of LiteLLM -- add an ALB Ingress or Gateway API
  resource pointed at the `litellm` Service for anything beyond
  port-forwarding.
- Persistent LiteLLM virtual keys/budgets -- the chart's bundled Postgres
  (`db.deployStandalone`) is ephemeral-friendly for a demo; wire
  `db.useExisting` to RDS for production.
- Multi-AZ pod spread for vLLM -- add a `topology_spread_constraint` block
  to the Deployment if you need it.
