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
  name             = "kueue"
  namespace        = "kueue-system"
  repository       = "oci://registry.k8s.io/kueue/charts"
  chart            = "kueue"
  version          = "0.9.1"
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
