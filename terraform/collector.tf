variable "collector_image_tag" {
  description = <<-EOT
    Tag of the finops-collector image in ECR. The repository has to exist
    before the image can be pushed, so `make deploy` applies the ECR resource
    on its own first, pushes, then applies everything else.

    Defaults to the short git SHA rather than "latest" so the tag is immutable
    and the deployment names exactly one build. `make deploy` passes it.
  EOT
  type        = string

  validation {
    condition     = var.collector_image_tag != "latest"
    error_message = "Use an immutable tag (the git SHA). The ECR repository rejects mutable tags, so 'latest' cannot be re-pushed anyway."
  }
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
          # checkov:skip=CKV_K8S_43:Pinned by immutable git-SHA tag against an
          #   IMMUTABLE ECR repository, which gives the same guarantee a digest
          #   does: the tag cannot be repointed at a different build.
          # checkov:skip=CKV_K8S_15:imagePullPolicy Always is pointless against
          #   an immutable tag; it re-pulls a byte-identical image on every
          #   restart. IfNotPresent is correct here.
          name              = "collector"
          image             = local.collector_image
          image_pull_policy = "IfNotPresent"

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

          # A wedged loop keeps the process alive while it stops doing work, so
          # liveness checks heartbeat freshness rather than process existence.
          # Three intervals of slack, since a tick that finds no GPU node is a
          # legitimate slow tick.
          liveness_probe {
            exec {
              command = [
                "python",
                "-c",
                "import sys,time,pathlib;p=pathlib.Path('/tmp/collector-heartbeat');sys.exit(0 if p.exists() and time.time()-int(p.read_text())<${var.collector_heartbeat_timeout} else 1)",
              ]
            }
            initial_delay_seconds = 30
            period_seconds        = 60
            failure_threshold     = 3
          }

          readiness_probe {
            exec {
              command = ["python", "-c", "import pathlib,sys;sys.exit(0 if pathlib.Path('/tmp/collector-heartbeat').exists() else 1)"]
            }
            initial_delay_seconds = 5
            period_seconds        = 15
          }

          # checkov:skip=CKV_K8S_11:CPU limits are omitted deliberately. A CPU
          # limit throttles via CFS quota rather than shedding load, which
          # would stall the collection loop under contention and produce gaps
          # in cost data. The request reserves the floor; memory is capped.
          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
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

        # read_only_root_filesystem is on, so the heartbeat needs somewhere
        # writable to live.
        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [
    aws_eks_pod_identity_association.collector,
    helm_release.prometheus,
  ]
}
