#!/usr/bin/env bash
#
# Submit N GPU jobs split across both tenant queues. With a nominal quota of 4
# and 12 jobs submitted, 4 admit and 8 sit pending, which is the point.

set -euo pipefail

COUNT="${1:-12}"

for i in $(seq 1 "$COUNT"); do
	# Alternate tenants so the cohort's borrowing behaviour is visible rather
	# than every job landing in one namespace.
	if ((i % 2 == 0)); then ns="team-a"; else ns="team-b"; fi

	cat <<-YAML | kubectl apply -f -
		apiVersion: batch/v1
		kind: Job
		metadata:
		  name: batch-job-${i}
		  namespace: ${ns}
		  labels:
		    kueue.x-k8s.io/queue-name: gpu
		    kueue.x-k8s.io/priority-class: low-priority
		spec:
		  suspend: true
		  parallelism: 1
		  completions: 1
		  backoffLimit: 0
		  template:
		    spec:
		      restartPolicy: Never
		      tolerations:
		        - key: nvidia.com/gpu
		          operator: Equal
		          value: "true"
		          effect: NoSchedule
		      containers:
		        - name: burn
		          image: nvcr.io/nvidia/cloud-native/dcgm:3.3.9-1-ubuntu22.04
		          command: ["/usr/bin/dcgmproftester12"]
		          args: ["--no-dcgm-validation", "-t", "1004", "-d", "120"]
		          resources:
		            limits:
		              nvidia.com/gpu: 1
		          securityContext:
		            capabilities:
		              add: ["SYS_ADMIN"]
	YAML
done

echo "submitted ${COUNT} jobs across team-a and team-b"
