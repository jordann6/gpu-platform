resource "kubernetes_namespace" "teams" {
  for_each = toset(["team-a", "team-b"])

  metadata {
    name = each.key
    labels = {
      "gpu-platform/tenant" = each.key
    }
  }
}

resource "kubectl_manifest" "gpu_flavor" {
  yaml_body = yamlencode({
    apiVersion = "kueue.x-k8s.io/v1beta1"
    kind       = "ResourceFlavor"
    metadata   = { name = "gpu-spot" }
    spec = {
      nodeLabels = { "workload-class" = "gpu" }
      # Kueue has to re-apply the Karpenter taint onto admitted workloads,
      # otherwise every admitted pod is unschedulable on the very nodes the
      # flavor points at.
      tolerations = [{
        key      = "nvidia.com/gpu"
        operator = "Equal"
        value    = "true"
        effect   = "NoSchedule"
      }]
    }
  })

  depends_on = [helm_release.kueue]
}

# One cohort, one queue. Both tenants draw from the same nominal quota, and
# borrowing lets an idle tenant's share be used rather than stranded.
resource "kubectl_manifest" "cluster_queue" {
  yaml_body = yamlencode({
    apiVersion = "kueue.x-k8s.io/v1beta1"
    kind       = "ClusterQueue"
    metadata   = { name = "gpu-queue" }
    spec = {
      namespaceSelector = {}
      cohort            = "gpu-cohort"
      # StrictFIFO, not BestEffortFIFO. A large job that cannot fit must block
      # the queue rather than let small jobs leapfrog it forever, which is the
      # starvation failure every naive GPU queue hits.
      queueingStrategy = "StrictFIFO"
      preemption = {
        withinClusterQueue  = "LowerPriority"
        reclaimWithinCohort = "Any"
        borrowWithinCohort  = { policy = "LowerPriority" }
      }
      resourceGroups = [{
        coveredResources = ["nvidia.com/gpu"]
        flavors = [{
          name = "gpu-spot"
          resources = [{
            name         = "nvidia.com/gpu"
            nominalQuota = tostring(var.gpu_quota)
          }]
        }]
      }]
    }
  })

  depends_on = [kubectl_manifest.gpu_flavor]
}

resource "kubectl_manifest" "local_queue" {
  for_each = kubernetes_namespace.teams

  yaml_body = yamlencode({
    apiVersion = "kueue.x-k8s.io/v1beta1"
    kind       = "LocalQueue"
    metadata = {
      name      = "gpu"
      namespace = each.key
    }
    spec = { clusterQueue = "gpu-queue" }
  })

  depends_on = [kubectl_manifest.cluster_queue]
}

resource "kubectl_manifest" "priority_classes" {
  for_each = {
    low  = 100
    high = 1000
  }

  yaml_body = yamlencode({
    apiVersion  = "kueue.x-k8s.io/v1beta1"
    kind        = "WorkloadPriorityClass"
    metadata    = { name = "${each.key}-priority" }
    value       = each.value
    description = "Kueue admission priority (${each.key})"
  })

  depends_on = [helm_release.kueue]
}
