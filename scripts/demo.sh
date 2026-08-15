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
	note "got ${desc} after $(($(date +%s) - start))s"
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

	# A Ready node is not the claim being made. The claim is that a GPU
	# workload runs on it, and those are separable: the node came up Ready and
	# advertised its card while every job on it exited 253 on a CUDA version
	# check, and this act still passed because it only ever looked at the node.
	wait_for "the GPU workload to start running" 300 \
		"kubectl get pods -n team-a -l job-name=gpu-job --no-headers 2>/dev/null | grep -qE ' (Running|Completed) '"

	if kubectl get pods -n team-a -l job-name=gpu-job --no-headers 2>/dev/null | grep -qE ' (Error|CrashLoopBackOff) '; then
		echo "FAIL: the GPU job did not run. Logs:" >&2
		kubectl logs -n team-a -l job-name=gpu-job --tail=20 >&2
		return 1
	fi
	# Printed only now. Before the workload runs, the device plugin has not
	# finished registering and the GPU column reads <none> on a node that does
	# in fact have a card.
	kubectl get nodes -l workload-class=gpu \
		-o custom-columns=NODE:.metadata.name,TYPE:.metadata.labels.node\\.kubernetes\\.io/instance-type,CAPACITY:.metadata.labels.karpenter\\.sh/capacity-type,GPU:.status.allocatable.nvidia\\.com/gpu

	note "GPU workload is running, so the card is genuinely usable"
}

# Act 2: quota. Twelve jobs against the ClusterQueue's nominal GPU quota; the
# remainder must queue rather than fail or oversubscribe. The quota tracks the
# granted G/VT service quota, so the admitted count is 2 here, not a constant.
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
	# Preemption is only observable against a saturated queue. Act 2's cohort
	# runs for a bounded time, so when this act runs on its own, or after any
	# delay, those jobs have drained and the high-priority job simply lands in
	# a free slot and evicts nobody, which still produced an empty eviction
	# table and a pass. So the queue is refilled here rather than assumed, and
	# saturation is measured as admitted workloads rather than Running pods:
	# pods terminating from a previous act still report Running, which read as
	# saturated within 2s while the new low-priority jobs had not yet started.
	local quota admitted
	quota=$(kubectl get clusterqueue gpu-queue \
		-o jsonpath='{.spec.resourceGroups[0].flavors[0].resources[0].nominalQuota}' 2>/dev/null)
	admitted=$(kubectl get clusterqueue gpu-queue -o jsonpath='{.status.admittedWorkloads}' 2>/dev/null)

	if ((${admitted:-0} < quota)); then
		note "only ${admitted:-0} of ${quota} GPU slots admitted; refilling with low-priority work first"
		./scripts/submit-batch.sh "$((quota * 2))"
		wait_for "the queue to saturate with low-priority work" 420 \
			"[ \"\$(kubectl get clusterqueue gpu-queue -o jsonpath='{.status.admittedWorkloads}' 2>/dev/null)\" -ge ${quota} ]"
	fi

	kubectl apply -f k8s/workloads/priority-job.yaml

	# kubectl get events exits 0 with no matches, so the absence of preemption
	# has to be tested on the output rather than the exit status.
	# The reason is "Preempted", not "EvictedDueToPreemption". Kueue 0.13
	# emits Preempted on the Workload (and Stopped on the Job), so the old
	# filter matched nothing and this act printed an empty table and passed.
	wait_for "a preemption event naming the high-priority job" 300 \
		"kubectl get events -A --field-selector reason=Preempted --no-headers 2>/dev/null | grep -q ."

	note "workloads by admission state (Kueue's own printer columns):"
	kubectl get workloads -A

	note "eviction events, which name the preemptor:"
	kubectl get events -A --field-selector reason=Preempted \
		-o custom-columns=NS:.metadata.namespace,OBJECT:.involvedObject.name,MESSAGE:.message

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

	# This must assert an actual increase across every GPU-bearing node, not
	# "items[0] is not 1". A node that is draining, or whose device plugin has
	# not registered yet, advertises 0, and 0 != 1 satisfied the old check
	# instantly: the act passed in 1s and printed an "after" table identical to
	# the "before" one, having proved nothing. Re-advertising takes ~60s.
	# This must assert an actual increase, not "items[0] is not 1". A node that
	# is draining, or whose device plugin has not registered yet, advertises 0,
	# and 0 != 1 satisfied the old check instantly: the act passed in 1s and
	# printed an "after" table identical to the "before" one, having proved
	# nothing. Re-advertising takes ~60s. Any node exceeding 1 is proof the
	# profile switched; requiring it of every node would hang on a drainer.
	wait_for "a GPU node to re-advertise more than one replica" 240 \
		"kubectl get nodes -l workload-class=gpu -o jsonpath='{.items[*].status.allocatable.nvidia\\.com/gpu}' | tr ' ' '\\n' | awk 'NF && \$1 > 1 {found=1} END {exit !found}'"

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

	# The claim is a graceful drain, and the evidence for it is Karpenter
	# cordoning the node with karpenter.sh/disrupted before the instance dies,
	# not the node eventually going away (a hard kill does that too). A fixed
	# sampling loop printed "Ready" twelve times and passed, because the notice
	# arrives minutes after the experiment starts. So wait for the taint, or
	# for the node object to be removed if the drain completes first.
	wait_for "Karpenter to cordon the node in response to the notice" 600 \
		"kubectl get node ${node} -o jsonpath='{.spec.taints[*].key}' 2>/dev/null | grep -q 'karpenter.sh/disrupted' || ! kubectl get node ${node} >/dev/null 2>&1"

	note "node condition after Karpenter reacted:"
	kubectl get node "$node" \
		-o custom-columns=NODE:.metadata.name,SCHEDULABLE:.spec.unschedulable,TAINT:.spec.taints[*].key \
		--no-headers 2>/dev/null || note "node already removed by Karpenter"

	note "the interruption controller's own account of it:"
	kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=500 2>/dev/null |
		grep -E '"controller":"interruption"|CordonAndDrain' | tail -3 ||
		note "(no interruption log lines found)"

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

	# The collector querying a metric nobody exports looks exactly like a
	# startup race: it logs "no GPU samples yet" once a minute and writes
	# nothing, forever. So wait for a real accounting line before reading
	# anything else, rather than printing 20 lines of that and calling it a
	# demo. dcgm-exporter does not ship SM_ACTIVE in its default metric set.
	wait_for "the collector to actually account for a GPU" 420 \
		"kubectl -n finops logs -l app=finops-collector --tail=40 2>/dev/null | grep -q 'interval spend'"

	note "collector logs (SM-active versus the utilization gauge that lies):"
	kubectl -n finops logs -l app=finops-collector --tail=6 || true

	note "cost records written (this is the attribution, per GPU per interval):"
	aws dynamodb scan --region "$REGION" --table-name "$TABLE" \
		--filter-expression 'record_type = :t' \
		--expression-attribute-values '{":t":{"S":"GPU_SAMPLE"}}' \
		--max-items 3 \
		--query 'Items[].{node:node.S,type:instance_type.S,life:lifecycle.S,sm_pct:sm_active_pct.N,cost:cost_usd.N,wasted:wasted_cost_usd.N}' \
		--output table 2>/dev/null || note "(cost table not readable)"

	# A query that matches nothing still exits 0, so the "no reap events" note
	# on the || branch could never fire and an empty table read as a result.
	local reaps idle_minutes
	reaps=$(aws dynamodb query --region "$REGION" --table-name "$TABLE" \
		--key-condition-expression 'pk = :p' \
		--expression-attribute-values '{":p":{"S":"REAP"}}' \
		--query 'Items[].{node:node.S,action:action.S,saving:projected_hourly_saving_usd.N}' \
		--output table 2>/dev/null || true)

	note "reap decisions recorded so far:"
	if [[ -n "$reaps" ]]; then
		printf '%s\n' "$reaps"
	else
		idle_minutes=$(kubectl -n finops get deploy finops-collector \
			-o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="IDLE_MINUTES")].value}' 2>/dev/null)
		note "none yet, and this is expected rather than a failure: a GPU must"
		note "stay below the SM-active threshold for ${idle_minutes:-30} minutes"
		note "before the reaper will act on it, which outlasts this demo. The"
		note "attribution above is the part that is provable in a short run."
	fi

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
