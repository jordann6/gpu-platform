resource "kubernetes_namespace" "gpu_operator" {
  metadata {
    name = "gpu-operator"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

# Two named profiles. "default" gives one workload exclusive use of the card.
# "shared" advertises the same physical GPU as N schedulable replicas, which is
# what the density half of the FinOps story measures against.
resource "kubernetes_config_map" "time_slicing" {
  metadata {
    name      = "time-slicing-config"
    namespace = kubernetes_namespace.gpu_operator.metadata[0].name
  }

  data = {
    "default" = yamlencode({
      version = "v1"
      flags   = { migStrategy = "none" }
    })
    "shared" = yamlencode({
      version = "v1"
      flags   = { migStrategy = "none" }
      sharing = {
        timeSlicing = {
          # Oversubscription is cooperative, not enforced. Replicas share the
          # card by context switching, so each sees full memory and can OOM a
          # neighbour. That tradeoff is the point of the comparison.
          resources = [{
            name     = "nvidia.com/gpu"
            replicas = var.time_slicing_replicas
          }]
        }
      }
    })
  }
}

# The stock dcgm-exporter metric list with DCGM_FI_PROF_SM_ACTIVE added. The
# profiling counters are the ones worth having: DCGM_FI_DEV_GPU_UTIL reports
# kernel residency, so a single resident kernel using one SM reads as 100%
# busy. SM_ACTIVE is the fraction of SMs with at least one warp resident,
# which is what distinguishes a genuinely loaded card from an idle holder.
resource "kubernetes_config_map" "dcgm_metrics" {
  metadata {
    name      = "dcgm-metrics-sm-active"
    namespace = kubernetes_namespace.gpu_operator.metadata[0].name
  }

  data = {
    "dcgm-metrics.csv" = <<-CSV
      DCGM_FI_PROF_SM_ACTIVE,            gauge, Fraction of SMs with at least one warp resident.
      DCGM_FI_PROF_GR_ENGINE_ACTIVE,     gauge, Fraction of time the graphics engine was active.
      DCGM_FI_PROF_PIPE_TENSOR_ACTIVE,   gauge, Fraction of cycles the tensor pipes were active.
      DCGM_FI_PROF_DRAM_ACTIVE,          gauge, Fraction of cycles device memory was active.
      DCGM_FI_DEV_GPU_UTIL,              gauge, GPU utilization as reported by the driver.
      DCGM_FI_DEV_MEM_COPY_UTIL,         gauge, Memory utilization.
      DCGM_FI_DEV_FB_FREE,               gauge, Framebuffer memory free (MiB).
      DCGM_FI_DEV_FB_USED,               gauge, Framebuffer memory used (MiB).
      DCGM_FI_DEV_GPU_TEMP,              gauge, GPU temperature (C).
      DCGM_FI_DEV_POWER_USAGE,           gauge, Power draw (W).
      DCGM_FI_DEV_SM_CLOCK,              gauge, SM clock (MHz).
      DCGM_FI_DEV_XID_ERRORS,            gauge, Last XID error (0 when none).
    CSV
  }
}

resource "helm_release" "gpu_operator" {
  name       = "gpu-operator"
  namespace  = kubernetes_namespace.gpu_operator.metadata[0].name
  repository = "https://helm.ngc.nvidia.com/nvidia"
  chart      = "gpu-operator"
  version    = "v24.9.1"
  wait       = true
  timeout    = 900

  values = [yamlencode({
    # The AL2023 accelerated AMI already carries the driver and the container
    # toolkit. Letting the operator install its own produces two drivers and a
    # node that never reaches Ready.
    driver  = { enabled = false }
    toolkit = { enabled = false }

    devicePlugin = {
      config = {
        name    = kubernetes_config_map.time_slicing.metadata[0].name
        default = "default"
      }
    }

    # MIG manager is deployed but inert. No instance family this project can
    # afford supports MIG: T4 (g4dn) and A10G (g5) both lack it, and the
    # cheapest MIG-capable option is p4d.24xlarge at roughly $32/hr. The
    # profiles in k8s/gpu-operator/mig-profiles.yaml are the configuration
    # path, documented rather than demonstrated.
    migManager = { enabled = false }

    dcgmExporter = {
      enabled = true
      serviceMonitor = {
        enabled  = true
        interval = "15s"
      }
      # The stock metric set does NOT include DCGM_FI_PROF_SM_ACTIVE. It ships
      # GR_ENGINE_ACTIVE, DRAM_ACTIVE and PIPE_TENSOR_ACTIVE, and the whole
      # FinOps side of this project queries SM_ACTIVE, so with the default
      # config the collector logs "returned no series" forever, writes no cost
      # records, and the reaper never makes a decision. Nothing errors: it just
      # silently measures nothing.
      config = { name = kubernetes_config_map.dcgm_metrics.metadata[0].name }
    }

    # Operator components run on system nodes; only the daemonsets belong on
    # GPU hardware.
    operator = {
      nodeSelector = { "workload-class" = "system" }
    }
    node-feature-discovery = {
      master = {
        nodeSelector = { "workload-class" = "system" }
      }
    }
  })]

  depends_on = [
    kubectl_manifest.gpu_node_pool,
    helm_release.prometheus,
  ]
}

resource "helm_release" "prometheus" {
  name             = "kube-prometheus-stack"
  namespace        = "monitoring"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "65.3.1"
  create_namespace = true
  wait             = true
  timeout          = 900

  values = [yamlencode({
    prometheus = {
      prometheusSpec = {
        nodeSelector = { "workload-class" = "system" }
        # The GPU Operator installs its ServiceMonitor in its own namespace
        # with its own labels, so the default label selector has to come off
        # or DCGM metrics silently never arrive.
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        retention                               = "12h"
        resources = {
          requests = { cpu = "200m", memory = "1Gi" }
          limits   = { memory = "2Gi" }
        }
      }
    }
    grafana = {
      enabled      = true
      nodeSelector = { "workload-class" = "system" }
      # Demo-only cluster reached through kubectl port-forward, never exposed.
      service = { type = "ClusterIP" }
    }
    alertmanager = { enabled = false }
    # kubelet/node-exporter defaults are fine; the metrics that matter here
    # come from DCGM.
  })]

  depends_on = [module.eks]
}

resource "helm_release" "kueue" {
  name       = "kueue"
  namespace  = "kueue-system"
  repository = "oci://registry.k8s.io/kueue/charts"
  chart      = "kueue"
  # registry.k8s.io prunes old Kueue chart versions rather than keeping them
  # forever, so a pin that resolved when this was written can start returning
  # "not found" with no config change on this side. 0.9.1 died that way; the
  # oldest still published is 0.11.0. The controllerManager.manager.resources
  # values schema below is unchanged across this bump.
  version          = "0.13.0"
  create_namespace = true
  wait             = true
  timeout          = 600

  values = [yamlencode({
    controllerManager = {
      manager = {
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { memory = "512Mi" }
        }
      }
    }
    nodeSelector = { "workload-class" = "system" }
  })]

  depends_on = [module.eks]
}
