# ---------- Cluster / network ----------
variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  description = "Base name used for the VPC and EKS cluster"
  type        = string
  default     = "llm-demo"
}

variable "kubernetes_version" {
  type    = string
  default = "1.35"
}

variable "vpc_cidr" {
  type    = string
  default = "10.60.0.0/16"
}

variable "az_count" {
  description = "Number of AZs to spread private/public subnets across"
  type        = number
  default     = 2
}

variable "single_nat_gateway" {
  description = "true = one shared NAT gateway (cheaper demo); false = one per AZ (prod)"
  type        = bool
  default     = true
}

variable "system_node_instance_types" {
  description = "Instance types for the small always-on system node group (CoreDNS, Karpenter, KEDA, Prometheus, LiteLLM)"
  type        = list(string)
  default     = ["m6i.large"]
}

variable "system_node_desired_size" {
  type    = number
  default = 2
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ---------- Karpenter ----------
variable "karpenter_version" {
  type    = string
  default = "1.9.0"
}

variable "karpenter_default_instance_types" {
  description = "Instance families for the non-GPU default NodePool"
  type        = list(string)
  default     = ["m6i", "m5"]
}

variable "vllm_instance_types" {
  description = "GPU instance types Karpenter may launch for vLLM"
  type        = list(string)
  default     = ["g5.xlarge", "g5.2xlarge", "g5.4xlarge", "g6.xlarge", "g6.2xlarge"]
}

variable "vllm_capacity_type" {
  description = "Karpenter capacity type for the GPU NodePool: on-demand or spot"
  type        = string
  default     = "spot"
}

# ---------- KEDA ----------
variable "keda_version" {
  type    = string
  default = "2.20.2"
}

variable "keda_scale_metric_threshold" {
  description = "Target value of vllm:num_requests_waiting per replica before KEDA scales out"
  type        = number
  default     = 5
}

variable "vllm_replicas_min" {
  type    = number
  default = 1
}

variable "vllm_replicas_max" {
  type    = number
  default = 4
}

# ---------- Prometheus (backs the KEDA scaler; scrapes vLLM's /metrics) ----------
variable "enable_prometheus" {
  description = "Install a minimal kube-prometheus-stack for the KEDA vLLM scaler. Set false if you already run Prometheus."
  type        = bool
  default     = true
}

variable "kube_prometheus_stack_version" {
  type    = string
  default = "68.4.2"
}

variable "prometheus_server_address" {
  description = "Only used when enable_prometheus = false -- point at your existing Prometheus"
  type        = string
  default     = "http://kube-prometheus-stack-prometheus.monitoring.svc:9090"
}

# ---------- NVIDIA device plugin ----------
variable "nvidia_device_plugin_version" {
  type    = string
  default = "0.17.1"
}

# ---------- vLLM GPU/CPU toggle ----------
# Flip to false to run vLLM on ordinary CPU instances (via the "default"
# NodePool) instead of GPU instances -- useful for demoing the rest of the
# stack (Karpenter, KEDA, LiteLLM) while a GPU quota increase is pending.
variable "vllm_use_gpu" {
  type    = bool
  default = true
}

# ---------- vLLM model configuration (GPU mode) ----------
variable "vllm_image_repository" {
  type    = string
  default = "vllm/vllm-openai"
}

variable "vllm_image_tag" {
  type    = string
  default = "v0.8.5"
}

variable "vllm_model_name" {
  description = "HuggingFace model repo id or local path"
  type        = string
  default     = "meta-llama/Llama-3.1-8B-Instruct"
}

variable "vllm_served_model_name" {
  description = "Name clients / LiteLLM use to address this model"
  type        = string
  default     = "llama-3.1-8b"
}

variable "vllm_gpu_count" {
  type    = number
  default = 1
}

variable "vllm_tensor_parallel_size" {
  type    = number
  default = 1
}

variable "vllm_gpu_memory_utilization" {
  type    = number
  default = 0.90
}

variable "vllm_max_model_len" {
  type    = number
  default = 8192
}

variable "vllm_dtype" {
  type    = string
  default = "auto"
}

variable "vllm_quantization" {
  description = "e.g. awq, gptq, fp8 -- leave empty for none"
  type        = string
  default     = ""
}

variable "vllm_extra_args" {
  description = "Any additional raw vLLM CLI flags, e.g. [\"--enable-prefix-caching\"]"
  type        = list(string)
  default     = []
}

# ---------- vLLM model configuration (CPU mode, vllm_use_gpu = false) ----------
# Official vLLM-project CPU image, built from docker/Dockerfile.cpu and
# published to AWS public ECR -- not the CUDA-only vllm/vllm-openai image.
# Check https://gallery.ecr.aws/q9t5s3a7/vllm-cpu-release-repo for newer tags.
variable "vllm_cpu_image_repository" {
  type    = string
  default = "public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo"
}

variable "vllm_cpu_image_tag" {
  type    = string
  default = "v0.9.1"
}

variable "vllm_cpu_model_name" {
  description = "Small, CPU-friendly model -- an 8B model is impractically slow without a GPU"
  type        = string
  default     = "Qwen/Qwen2.5-0.5B-Instruct"
}

variable "vllm_cpu_max_model_len" {
  type    = number
  default = 4096
}

variable "vllm_cpu_dtype" {
  description = "float32 is the safest default; bfloat16/float16 need AVX512_BF16 on the host CPU"
  type        = string
  default     = "auto"
}

variable "vllm_cpu_kvcache_space_gb" {
  description = "VLLM_CPU_KVCACHE_SPACE -- GiB of host RAM reserved for the KV cache"
  type        = number
  default     = 4
}

variable "vllm_cpu_request" {
  type    = string
  default = "4"
}

variable "vllm_cpu_limit" {
  type    = string
  default = "8"
}

variable "vllm_mem_request" {
  type    = string
  default = "16Gi"
}

variable "vllm_mem_limit" {
  type    = string
  default = "32Gi"
}

variable "vllm_shm_size" {
  type    = string
  default = "8Gi"
}

variable "hf_token" {
  description = "HuggingFace token for gated models (leave empty for public models)"
  type        = string
  default     = ""
  sensitive   = true
}

# ---------- LiteLLM ----------
variable "litellm_chart_version" {
  type    = string
  default = "1.104.0-rc.2"
}

variable "litellm_master_key" {
  description = "API key clients must send to LiteLLM. Generated randomly if left empty."
  type        = string
  default     = ""
  sensitive   = true
}

variable "litellm_replicas" {
  type    = number
  default = 2
}
