variable "aws_region" {
  description = "Region for the cluster and all supporting resources."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment suffix applied to every resource name."
  type        = string
  default     = "dev"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "gpu-platform"
}

variable "kubernetes_version" {
  description = "EKS control plane version."
  type        = string
  default     = "1.31"
}

variable "vpc_cidr" {
  description = "CIDR for the platform VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "gpu_instance_families" {
  description = <<-EOT
    Instance families Karpenter may provision for GPU work: g4dn (T4), g5
    (A10G), g6 (L4) and g6e (L40S). None supports MIG, which is why the MIG
    profiles in k8s/gpu-operator ship as a documented configuration path
    rather than a deployed one.

    All four are listed for spot diversity, not because the demo needs four
    accelerators. The NodePool pins one GPU and a fixed vCPU count, so exactly
    one size per family qualifies. With only g4dn and g5 that left a single
    viable instance type once the vCPU pin applied, and provisioning failed
    outright with "InsufficientInstanceCapacity: There is no Spot capacity
    available" whenever that one pool was dry. Karpenter asks for at least
    five instance types when flexible to spot; four is the most this quota
    and this GPU-count constraint allow.
  EOT
  type        = list(string)
  default     = ["g4dn", "g5", "g6", "g6e"]
}

variable "gpu_cpu_limit" {
  description = <<-EOT
    Ceiling on total vCPUs Karpenter may provision for GPU nodes. Held at 8 to
    match the account service quota actually granted for L-DB2E81BA and
    L-3819A6DF, so a runaway NodePool hits a Terraform-declared wall before it
    hits an AWS one. Both limits were requested at 32 and granted at 8 with the
    cases left open; raise this only after confirming the applied quota, because
    a value above the real quota inverts the point of the variable and Karpenter
    returns VcpuLimitExceeded instead of a clean unschedulable pod.
  EOT
  type        = number
  default     = 8
}

variable "gpu_node_expire_after" {
  description = "Hard TTL on any GPU node, so nothing outlives a demo window."
  type        = string
  default     = "8h"
}

variable "time_slicing_replicas" {
  description = "GPU replicas advertised per physical device when time-slicing is enabled."
  type        = number
  default     = 4
}

variable "gpu_quota" {
  description = <<-EOT
    Nominal nvidia.com/gpu quota held by the Kueue ClusterQueue.

    Held at 2, which is what the cluster can actually schedule: the granted
    G/VT quota is 8 vCPUs and the NodePool pins instance-gpu-count to 1, so
    8 vCPUs buys 2 physical cards, and the device plugin ships the exclusive
    "default" profile rather than the time-sliced "shared" one. A nominalQuota
    above the schedulable count is worse than a low one, because Kueue admits
    workloads that then sit Pending forever instead of queueing honestly.

    With the "shared" profile applied this can rise to
    2 x time_slicing_replicas.
  EOT
  type        = number
  default     = 2
}

variable "reaper_idle_threshold_pct" {
  description = "SM-active percentage below which a GPU counts as idle."
  type        = number
  default     = 5
}

variable "reaper_idle_minutes" {
  description = "Minutes a GPU must stay below the idle threshold before the reaper acts."
  type        = number
  default     = 30
}

variable "collector_heartbeat_timeout" {
  description = "Seconds of heartbeat staleness before the collector is judged wedged."
  type        = number
  default     = 300
}

variable "reaper_dry_run" {
  description = <<-EOT
    When true the reaper logs and records what it would terminate without
    deleting anything. Ships true on purpose: an autonomous terminator of
    expensive hardware that has never been watched in dry-run is a liability.
  EOT
  type        = bool
  default     = true
}

variable "create_spot_service_linked_role" {
  description = <<-EOT
    Create the EC2 spot service-linked role. It is required before any spot
    RunInstances call succeeds, and a fresh account does not have it: without
    it Karpenter silently falls back to on-demand, which quietly voids both
    the spot savings this project measures and the FIS interruption demo.
    Set false in an account that already has the role, since it is global and
    creating it twice fails.
  EOT
  type        = bool
  default     = true
}
