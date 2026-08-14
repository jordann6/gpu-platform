module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.31"

  cluster_name = module.eks.cluster_name

  # Pod Identity rather than IRSA. Fewer moving parts and the addon is already
  # installed on the cluster above.
  enable_pod_identity             = true
  create_pod_identity_association = true

  # Karpenter needs to read the spot interruption and rebalance notices that
  # EventBridge drops into this queue, which is what makes act 5 of the demo
  # (kill a spot node mid-job, watch the workload requeue) work gracefully
  # instead of as a hard kill.
  enable_spot_termination = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}

resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = "kube-system"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.0.8"
  create_namespace = false
  wait             = true

  values = [yamlencode({
    settings = {
      clusterName       = module.eks.cluster_name
      clusterEndpoint   = module.eks.cluster_endpoint
      interruptionQueue = module.karpenter.queue_name
    }
    serviceAccount = {
      name = module.karpenter.service_account
    }
    # Karpenter cannot schedule itself onto a node it has not created yet, so
    # it is pinned to the managed system group.
    nodeSelector = {
      "workload-class" = "system"
    }
    controller = {
      resources = {
        requests = { cpu = "500m", memory = "512Mi" }
        limits   = { memory = "512Mi" }
      }
    }
  })]

  depends_on = [module.eks]
}

# EC2NodeClass and NodePool are applied as raw manifests because they are CRDs
# the helm release above has only just installed.
resource "kubectl_manifest" "gpu_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = "gpu" }
    spec = {
      # AL2023 accelerated AMI ships the NVIDIA driver baked in, so the GPU
      # Operator runs with driver.enabled=false and nodes come up ready in
      # ~90s instead of waiting on a driver compile.
      amiFamily = "AL2023"
      amiSelectorTerms = [{
        alias = "al2023@latest"
      }]
      role = module.karpenter.node_iam_role_name
      subnetSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = local.name }
      }]
      securityGroupSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = local.name }
      }]
      blockDeviceMappings = [{
        deviceName = "/dev/xvda"
        ebs = {
          # CUDA images are large. The 20Gi default fills before the GPU
          # Operator finishes pulling and the node never goes Ready.
          volumeSize          = "100Gi"
          volumeType          = "gp3"
          encrypted           = true
          deleteOnTermination = true
        }
      }]
      tags = {
        Project     = "gpu-platform"
        Environment = var.environment
        Owner       = "jordan"
        ManagedBy   = "karpenter"
      }
    }
  })

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "gpu_node_pool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "gpu" }
    spec = {
      template = {
        metadata = {
          labels = { "workload-class" = "gpu" }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "gpu"
          }
          # Only workloads that tolerate this taint may land on hardware that
          # costs 6x a system node.
          taints = [{
            key    = "nvidia.com/gpu"
            value  = "true"
            effect = "NoSchedule"
          }]
          requirements = [
            {
              key      = "karpenter.k8s.aws/instance-family"
              operator = "In"
              values   = var.gpu_instance_families
            },
            {
              # Spot first. On-demand stays in the list as fallback so a
              # capacity-starved demo still runs, just more expensively.
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["spot", "on-demand"]
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "karpenter.k8s.aws/instance-gpu-count"
              operator = "In"
              values   = ["1"]
            },
          ]
          expireAfter = var.gpu_node_expire_after
        }
      }
      limits = {
        cpu = tostring(var.gpu_cpu_limit)
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1m"
      }
    }
  })

  depends_on = [kubectl_manifest.gpu_node_class]
}
