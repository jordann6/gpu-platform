#!/usr/bin/env bash
#
# The six demo acts. Each one prints the evidence it produced, because the
# receipt is the deliverable here, not the infrastructure.
#
# Usage: ./scripts/demo.sh <act|all>

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
TABLE="${TABLE_NAME:-gpu-platform-dev-costs}"

banner() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }

wait_for() {
	local desc="$1" timeout="$2" cmd="${*:3}"
	local start
	start=$(date +%s)
	note "waiting for ${desc} (timeout ${timeout}s)"
	until eval "$cmd" >/dev/null 2>&1; do
		if (($(date +%s) - start > timeout)); then
			echo "TIMEOUT waiting for ${desc}" >&2
			return 1
		fi
		sleep 5
	done
	note "${desc} after $(($(date +%s) - start))s"
}

gpu_nodes() {
	kubectl get nodes -l workload-class=gpu -o name 2>/dev/null | wc -l | tr -d ' '
}

# Act 1: cold start. No GPU node exists; submitting one job should make
# Karpenter provision hardware from nothing.
act1_provision() {
	banner "Act 1: Karpenter provisions a GPU node from zero"
	note "GPU nodes before: $(gpu_nodes)"

	kubectl apply -f k8s/workloads/gpu-job.yaml
	wait_for "a GPU node to join Ready" 300 \
		"kubectl get nodes -l workload-class=gpu --no-headers 2>/dev/null | grep -q ' Ready '"

	kubectl get nodes -l workload-class=gpu \
		-o custom-columns=NODE:.metadata.name,TYPE:.metadata.labels.node\\.kubernetes\\.io/instance-type,CAPACITY:.metadata.labels.karpenter\\.sh/capacity-type,GPU:.status.allocatable.nvidia\\.com/gpu
}

# Act 2: quota. Twelve jobs against four GPUs; eight must queue rather than
# fail or oversubscribe.
act2_quota() {
	banner "Act 2: Kueue admits to quota and queues the rest"
	./scripts/submit-batch.sh 12

	sleep 30
	note "ClusterQueue state:"
	kubectl get clusterqueue gpu-queue \
		-o custom-columns=NAME:.metadata.name,ADMITTED:.status.admittedWorkloads,PENDING:.status.pendingWorkloads

	note "a job is only managed by Kueue if it carries the queue-name label;"
	note "without it a job bypasses quota entirely and schedules directly"
}

# Act 3: preemption. A high-priority job must evict a low-priority one and the
# evicted work must requeue rather than vanish.
act3_preemption() {
	banner "Act 3: high-priority workload preempts and the victim requeues"
	kubectl apply -f k8s/workloads/priority-job.yaml

	sleep 45
	note "workloads by admission state (Kueue's own printer columns):"
	kubectl get workloads -A

	note "eviction events, which name the preemptor:"
	kubectl get events -A --field-selector reason=EvictedDueToPreemption \
		-o custom-columns=NS:.metadata.namespace,OBJECT:.involvedObject.name,MESSAGE:.message 2>/dev/null ||
		note "(no preemption events yet)"

	note "evicted workloads return to the queue; they are not lost"
}

# Act 4: density. The same load on a dedicated card versus a time-sliced one,
# with cost per job on each.
act4_density() {
	banner "Act 4: dedicated versus time-sliced density"

	note "advertised GPUs per node, default profile (exclusive):"
	kubectl get nodes -l workload-class=gpu \
		-o custom-columns=NODE:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu

	note "switching the device plugin to the shared profile..."
	kubectl label node -l workload-class=gpu \
		nvidia.com/device-plugin.config=shared --overwrite

	wait_for "the device plugin to re-advertise replicas" 240 \
		"[ \"\$(kubectl get nodes -l workload-class=gpu -o jsonpath='{.items[0].status.allocatable.nvidia\\.com/gpu}')\" != '1' ]"

	note "advertised GPUs per node, shared profile (time-sliced):"
	kubectl get nodes -l workload-class=gpu \
		-o custom-columns=NODE:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu

	note "the physical card did not change. Time-slicing is cooperative"
	note "context switching, so each replica sees full memory and can OOM a"
	note "neighbour. That tradeoff is the reason MIG exists, and the reason"
	note "T4 and A10G cannot do MIG is in k8s/gpu-operator/mig-profiles.yaml"
}

# Act 5: spot interruption. Karpenter's interruption queue should drain the
# node gracefully and Kueue should requeue the job.
act5_spot() {
	banner "Act 5: spot interruption drains gracefully and work requeues"

	local node template experiment
	node=$(kubectl get nodes -l workload-class=gpu,karpenter.sh/capacity-type=spot \
		-o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

	if [[ -z "$node" ]]; then
		note "no spot GPU node present (capacity fell back to on-demand); skipping"
		return 0
	fi

	template=$(terraform -chdir=terraform output -raw fis_template_id)
	note "interrupting spot node ${node} via FIS template ${template}"
	note "this is the real ITN path: rebalance recommendation, then a"
	note "two-minute notice, mirrored by EventBridge into Karpenter's queue."
	note "a TerminateInstances call would prove nothing about draining."

	experiment=$(aws fis start-experiment --region "$REGION" \
		--experiment-template-id "$template" \
		--query 'experiment.id' --output text)
	note "experiment ${experiment} started"

	note "node condition as Karpenter reacts:"
	for _ in $(seq 1 12); do
		kubectl get node "$node" \
			-o custom-columns=NODE:.metadata.name,SCHEDULABLE:.spec.unschedulable,STATUS:.status.conditions[-1].type \
			--no-headers 2>/dev/null || break
		sleep 15
	done

	note "workloads should have requeued rather than failed:"
	kubectl get workloads -A
}

# Act 6: the reaper. An idle GPU holder should be flagged in dry-run with a
# dollar figure attached before anything is ever deleted.
act6_reaper() {
	banner "Act 6: idle-GPU reaper, dry-run first"

	kubectl apply -f k8s/workloads/idle-holder.yaml
	note "an idle holder now occupies a GPU and does no work with it"
	note "this is invisible to any tool that reports at instance granularity:"
	note "the instance looks perfectly busy from outside"

	note "collector logs (SM-active versus the utilization gauge that lies):"
	kubectl -n finops logs -l app=finops-collector --tail=20 || true

	note "reap decisions recorded so far:"
	aws dynamodb query --region "$REGION" --table-name "$TABLE" \
		--key-condition-expression 'pk = :p' \
		--expression-attribute-values '{":p":{"S":"REAP"}}' \
		--query 'Items[].{node:node.S,action:action.S,saving:projected_hourly_saving_usd.N}' \
		--output table 2>/dev/null || note "(no reap events yet; the idle window has not elapsed)"

	note "to arm it for real: terraform apply -var reaper_dry_run=false"
}

case "${1:-all}" in
	1 | provision) act1_provision ;;
	2 | quota) act2_quota ;;
	3 | preemption) act3_preemption ;;
	4 | density) act4_density ;;
	5 | spot) act5_spot ;;
	6 | reaper) act6_reaper ;;
	all)
		act1_provision
		act2_quota
		act3_preemption
		act4_density
		act5_spot
		act6_reaper
		;;
	*)
		echo "usage: $0 {1..6|all}" >&2
		exit 2
		;;
esac
