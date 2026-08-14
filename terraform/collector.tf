variable "collector_image_tag" {
  description = <<-EOT
    Tag of the finops-collector image in ECR. The repository has to exist
    before the image can be pushed, so `make deploy` applies the ECR resource
    on its own first, pushes, then applies everything else.
  EOT
  type        = string
  default     = "latest"
}

locals {
  collector_image = "${aws_ecr_repository.collector.repository_url}:${var.collector_image_tag}"

  prometheus_url = "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"
}

resource "kubernetes_deployment" "collector" {
  metadata {
    name      = "finops-collector"
    namespace = kubernetes_namespace.finops.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "finops-collector" }
    }

    template {
      metadata {
        labels = { app = "finops-collector" }
      }

      spec {
        service_account_name = kubernetes_service_account.collector.metadata[0].name
        node_selector        = { "workload-class" = "system" }

        container {
          name  = "collector"
          image = local.collector_image

          env {
            name  = "AWS_REGION"
            value = var.aws_region
          }
          env {
            name  = "PROMETHEUS_URL"
            value = local.prometheus_url
          }
          env {
            name  = "TABLE_NAME"
            value = aws_dynamodb_table.gpu_costs.name
          }
          env {
            name  = "IDLE_THRESHOLD_PCT"
            value = tostring(var.reaper_idle_threshold_pct)
          }
          env {
            name  = "IDLE_MINUTES"
            value = tostring(var.reaper_idle_minutes)
          }
          env {
            name  = "DRY_RUN"
            value = tostring(var.reaper_dry_run)
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }

          security_context {
            run_as_non_root            = true
            run_as_user                = 10001
            allow_privilege_escalation = false
            read_only_root_filesystem  = true

            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }

  depends_on = [
    aws_eks_pod_identity_association.collector,
    helm_release.prometheus,
  ]
}
