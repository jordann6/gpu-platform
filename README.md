# GPU Platform

Multi-tenant GPU scheduling on EKS with per-second cost attribution and an
idle-GPU reclaimer. Karpenter provisions spot GPU nodes on demand, Kueue
admits work against tenant quota with preemption, and a FinOps collector
measures what the fleet actually did with the silicon it rented.

![Architecture](docs/architecture.png)

## Cost and teardown, up front

Roughly **$0.50/hour** all-in: EKS control plane $0.10, two t3.medium system
nodes about $0.08, two g4dn.xlarge on spot about $0.32. A six-hour
deploy-demo-destroy window lands near **$3**.

Teardown risk is concentrated in one place: **Karpenter's GPU nodes are not
owned by the EKS module.** They carry finalizers and Terraform never tracked
the instances, so destroying the cluster first leaves ENIs attached to
instances the VPC delete then blocks on. `make destroy` deletes NodeClaims
first for that reason. Do not run `terraform destroy` on its own.

Nothing here is long-running. The `expireAfter` on the NodePool caps any GPU
node at 8 hours even if a teardown is forgotten.

## Prerequisites

The G and VT vCPU service quotas are **zero by default** on a fresh account,
in every region, and Karpenter will provision nothing until they are raised:

```
L-DB2E81BA   Running On-Demand G and VT instances
L-3819A6DF   All G and VT Spot Instance Requests
```

Both need to be at least 32 for this project. They are separate requests, they
are per-region, and they go to AWS support rather than resolving instantly.
File them before anything else.

## Deploy

```bash
make venv
make test        # 34 unit tests, terraform fmt + validate
make deploy      # ECR first, then push the image, then everything else
```

`make deploy` applies in three stages on purpose. The collector Deployment
references an image that must already exist, and the image cannot be pushed
until the ECR repository does, so the repository applies alone first.

## Demo

```bash
make demo              # all six acts
./scripts/demo.sh 4    # or one at a time
```

| Act | What it proves |
|---|---|
| 1 | Karpenter provisions a GPU node from zero in roughly 90 seconds |
| 2 | Kueue admits 4 of 12 jobs to quota and queues the other 8 |
| 3 | A high-priority job preempts a low-priority one, which requeues rather than dying |
| 4 | Time-slicing advertises one physical T4 as 4 schedulable GPUs, with cost per job on each |
| 5 | A real spot interruption drains gracefully and the workload requeues |
| 6 | The reaper flags an idle GPU with a dollar figure, in dry-run, before it is trusted to delete |

## Three things worth explaining

### The utilization metric everyone graphs is the wrong one

`DCGM_FI_DEV_GPU_UTIL` reports the fraction of time at least one kernel was
resident on the device. It does not report how much of the device was working.
A single small kernel looping on one SM pins that gauge at 100% while the rest
of the card idles, which is why GPU fleets routinely look saturated and are
mostly wasted.

The reaper keys on `DCGM_FI_PROF_SM_ACTIVE` instead, the profiling counter for
the fraction of SMs with a warp resident. Both are recorded on every sample so
the gap between them is visible in the data rather than asserted here.

### Cost Explorer cannot do this job

It reports at daily granularity and lags 8 to 24 hours, so a three-hour GPU
demo never appears in it while the demo is running. Accelerators are rented by
the second and go idle for minutes at a time, so the unit of waste is far
smaller than the smallest unit Cost Explorer can see.

Rates come from the Pricing API for on-demand and the spot price history for
spot; quantity comes from observed instance-seconds. The `wasted_cost_usd`
field is deliberately a linear function of SM occupancy. Fractional occupancy
does not map to fractional dollars in any rigorous way, since you rent the
whole card either way. It ranks nodes by waste. It is not an accounting figure.

### MIG is documented, not deployed

Multi-Instance GPU gives hardware-enforced isolation between slices, which
time-slicing cannot: time-slicing is cooperative context switching, so every
replica sees full memory and can OOM its neighbours.

MIG requires A100, H100, H200, B200, or A30 silicon. This project runs on T4
(g4dn) and A10G (g5), and **neither supports it**. That is not a driver flag or
a licensing tier, the partitioning hardware is absent. The cheapest MIG-capable
EC2 instance is p4d.24xlarge at roughly $32/hour behind its own quota gate,
about 100x this project's entire budget.

So act 4 measures dedicated versus time-sliced, both real and both on hardware
this project actually runs, and `k8s/gpu-operator/mig-profiles.yaml` carries
the full MIG configuration with the steps to enable it. Priced and declined,
rather than quietly skipped.

## Safety on the reaper

Automatically terminating expensive hardware fails badly when it fails, so the
reaper holds on four separate checks before it acts:

1. The node carries `workload-class=gpu`. System nodes are never candidates.
2. No admitted Kueue Workload is bound to it. A job between checkpoints reads
   as idle on SM occupancy and must not be killed for it.
3. No non-DaemonSet pods are running on it.
4. The idle streak spans the full window of consecutive samples, not one
   unlucky scrape.

If the Kueue API cannot be reached, the check fails safe and treats the node
as busy. And it ships in dry-run: `reaper_dry_run` defaults to `true`, writing
`would_terminate` records with the dollar figure attached. Arm it with
`terraform apply -var reaper_dry_run=false` once the dry-run records look
right.

It deletes the Karpenter **NodeClaim**, not the Node. Deleting a Node alone
accomplishes nothing, Karpenter reconciles a replacement within seconds.

## Layout

```
terraform/     VPC, EKS, Karpenter, GPU Operator, Kueue, Prometheus, FIS, DynamoDB
finops/        collector: Prometheus sampling, cost attribution, reaper
k8s/           NodePool, time-slicing config, MIG profiles, demo workloads
scripts/       the six demo acts
```

## Teardown

```bash
make destroy
```

Deletes NodeClaims first, then everything else, then prints any surviving
instance tagged `Project=gpu-platform` so a clean teardown is verified rather
than assumed.
