"""Idle-GPU reaper.

Terminating expensive hardware automatically is the kind of feature that pages
someone at 3am when it gets a corner case wrong, so the safety checks matter
more than the detection does. Four of them, in order of how badly they fail:

1. The node must carry workload-class=gpu. System nodes are never candidates.
2. No Kueue-admitted Workload may be bound to the node. A job between
   checkpoints reads as idle on SM occupancy and must not be killed for it.
3. No non-DaemonSet pods may be running on it.
4. The idle streak must span the full configured window of consecutive
   samples, not a single unlucky scrape.

And it ships in dry-run.
"""

from __future__ import annotations

import logging
from collections import defaultdict

from kubernetes import client, config
from kubernetes.client.rest import ApiException

log = logging.getLogger(__name__)

KARPENTER_GROUP = "karpenter.sh"
KARPENTER_VERSION = "v1"
KUEUE_GROUP = "kueue.x-k8s.io"
KUEUE_VERSION = "v1beta1"

GPU_NODE_LABEL = "workload-class"
GPU_NODE_VALUE = "gpu"


class Reaper:
    def __init__(self, samples_required: int, dry_run: bool = True) -> None:
        try:
            config.load_incluster_config()
        except config.ConfigException:
            config.load_kube_config()

        self.core = client.CoreV1Api()
        self.custom = client.CustomObjectsApi()
        self.samples_required = samples_required
        self.dry_run = dry_run
        self._idle_streak: dict[str, int] = defaultdict(int)

    def record(self, node: str, is_idle: bool) -> int:
        """Advance or reset a node's consecutive-idle counter."""
        if is_idle:
            self._idle_streak[node] += 1
        else:
            self._idle_streak[node] = 0
        return self._idle_streak[node]

    def forget(self, node: str) -> None:
        self._idle_streak.pop(node, None)

    def streak(self, node: str) -> int:
        return self._idle_streak.get(node, 0)

    def is_gpu_node(self, node: str) -> bool:
        try:
            obj = self.core.read_node(node)
        except ApiException as exc:
            if exc.status == 404:
                return False
            raise
        labels = obj.metadata.labels or {}
        return labels.get(GPU_NODE_LABEL) == GPU_NODE_VALUE

    def has_running_workload(self, node: str) -> bool:
        """True if anything other than DaemonSet infrastructure is on the node."""
        pods = self.core.list_pod_for_all_namespaces(
            field_selector=f"spec.nodeName={node},status.phase=Running"
        )
        for pod in pods.items:
            owners = pod.metadata.owner_references or []
            if any(o.kind == "DaemonSet" for o in owners):
                continue
            log.info("node %s still running pod %s/%s", node, pod.metadata.namespace, pod.metadata.name)
            return True
        return False

    def has_admitted_kueue_workload(self, node: str) -> bool:
        """True if an admitted Kueue Workload has pods on this node.

        Kueue Workloads do not name nodes, so admission is resolved through the
        pods they own. A checkpointing job can look idle on SM occupancy for
        minutes, and killing it would lose the work the queue already paid for.
        """
        try:
            workloads = self.custom.list_cluster_custom_object(
                group=KUEUE_GROUP, version=KUEUE_VERSION, plural="workloads"
            )
        except ApiException as exc:
            log.warning("could not list Kueue workloads (%s); failing safe", exc.status)
            return True

        admitted_uids = set()
        for wl in workloads.get("items", []):
            conditions = wl.get("status", {}).get("conditions", [])
            if any(c.get("type") == "Admitted" and c.get("status") == "True" for c in conditions):
                for ref in wl.get("metadata", {}).get("ownerReferences", []):
                    admitted_uids.add(ref.get("uid"))

        if not admitted_uids:
            return False

        pods = self.core.list_pod_for_all_namespaces(
            field_selector=f"spec.nodeName={node}"
        )
        for pod in pods.items:
            for owner in pod.metadata.owner_references or []:
                if owner.uid in admitted_uids:
                    return True
        return False

    def find_node_claim(self, node: str) -> str | None:
        """Karpenter's NodeClaim is the real owner of the instance.

        Deleting the Node object alone accomplishes nothing: Karpenter
        reconciles the NodeClaim and a replacement appears within seconds.
        """
        claims = self.custom.list_cluster_custom_object(
            group=KARPENTER_GROUP, version=KARPENTER_VERSION, plural="nodeclaims"
        )
        for claim in claims.get("items", []):
            if claim.get("status", {}).get("nodeName") == node:
                return claim["metadata"]["name"]
        return None

    def eligible(self, node: str) -> tuple[bool, str]:
        if self.streak(node) < self.samples_required:
            return False, f"idle streak {self.streak(node)}/{self.samples_required}"
        if not self.is_gpu_node(node):
            return False, "not a GPU node"
        if self.has_admitted_kueue_workload(node):
            return False, "admitted Kueue workload bound to node"
        if self.has_running_workload(node):
            return False, "non-DaemonSet pods still running"
        return True, "idle beyond threshold with no workload"

    def reap(self, node: str) -> bool:
        """Cordon then delete the backing NodeClaim. Returns True if acted."""
        ok, reason = self.eligible(node)
        if not ok:
            log.debug("node %s not eligible: %s", node, reason)
            return False

        if self.dry_run:
            log.info("DRY RUN: would reap node %s (%s)", node, reason)
            return False

        log.info("reaping node %s (%s)", node, reason)
        self.core.patch_node(node, {"spec": {"unschedulable": True}})

        claim = self.find_node_claim(node)
        if claim is None:
            log.warning("no NodeClaim found for %s; cordoned only", node)
            return False

        self.custom.delete_cluster_custom_object(
            group=KARPENTER_GROUP,
            version=KARPENTER_VERSION,
            plural="nodeclaims",
            name=claim,
        )
        # Karpenter's finalizer drains the node before the instance goes away,
        # so no explicit eviction loop is needed here.
        self.forget(node)
        return True
