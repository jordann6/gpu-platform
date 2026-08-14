"""Prometheus queries against the DCGM exporter.

The metric choice here is the whole point of the project, so it is worth being
explicit about it.

`DCGM_FI_DEV_GPU_UTIL` is what every naive GPU dashboard graphs, and it lies.
It reports the fraction of time at least one kernel was resident, not how much
of the card was doing work. A single tiny kernel looping on one SM pins it at
100% while 99% of the silicon idles, so a fleet can look saturated and be
almost entirely wasted.

`DCGM_FI_PROF_SM_ACTIVE` is the profiling counter for the fraction of SMs with
a warp resident. That is the number that tracks money. The reaper uses it and
records the other one alongside purely to show the gap.
"""

from __future__ import annotations

import logging
from collections.abc import Iterable
from dataclasses import dataclass

import requests

log = logging.getLogger(__name__)

# The DCGM exporter's node label is not stable across chart versions and
# ServiceMonitor relabelings, so the first label that is actually present wins
# rather than hardcoding one and silently collecting nothing.
NODE_LABEL_CANDIDATES = ("kubernetes_node", "Hostname", "node", "instance")

SM_ACTIVE = "DCGM_FI_PROF_SM_ACTIVE"
GPU_UTIL = "DCGM_FI_DEV_GPU_UTIL"
FB_USED = "DCGM_FI_DEV_FB_USED"
FB_TOTAL = "DCGM_FI_DEV_FB_FREE"


@dataclass(frozen=True)
class GpuSample:
    node: str
    sm_active_pct: float
    gpu_util_pct: float
    fb_used_mib: float
    gpu_count: int


class PrometheusError(RuntimeError):
    pass


class Prometheus:
    def __init__(self, base_url: str, timeout: int = 10) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self._node_label: str | None = None

    def query(self, expr: str) -> list[dict]:
        resp = requests.get(
            f"{self.base_url}/api/v1/query",
            params={"query": expr},
            timeout=self.timeout,
        )
        resp.raise_for_status()
        payload = resp.json()
        if payload.get("status") != "success":
            raise PrometheusError(f"query failed: {expr}: {payload}")
        return payload["data"]["result"]

    def detect_node_label(self) -> str:
        """Find which label on the DCGM metrics identifies the node."""
        if self._node_label:
            return self._node_label

        result = self.query(SM_ACTIVE)
        if not result:
            raise PrometheusError(
                f"{SM_ACTIVE} returned no series. Either no GPU node is up yet, "
                "or the DCGM ServiceMonitor is not being scraped."
            )

        labels = result[0].get("metric", {})
        for candidate in NODE_LABEL_CANDIDATES:
            if candidate in labels:
                self._node_label = candidate
                log.info("using %r as the DCGM node label", candidate)
                return candidate

        raise PrometheusError(
            f"none of {NODE_LABEL_CANDIDATES} present on {SM_ACTIVE}; "
            f"available labels: {sorted(labels)}"
        )

    def _by_node(self, metric: str, node_label: str) -> dict[str, float]:
        out: dict[str, float] = {}
        for series in self.query(f"avg by ({node_label}) ({metric})"):
            node = series["metric"].get(node_label)
            if not node:
                continue
            out[node] = float(series["value"][1])
        return out

    def _count_by_node(self, metric: str, node_label: str) -> dict[str, int]:
        out: dict[str, int] = {}
        for series in self.query(f"count by ({node_label}) ({metric})"):
            node = series["metric"].get(node_label)
            if not node:
                continue
            out[node] = int(float(series["value"][1]))
        return out

    def sample(self) -> list[GpuSample]:
        node_label = self.detect_node_label()

        # SM_ACTIVE and GPU_UTIL are on different scales in DCGM: the profiling
        # counter is a 0-1 ratio, the utilization gauge is already a percent.
        sm = self._by_node(SM_ACTIVE, node_label)
        util = self._by_node(GPU_UTIL, node_label)
        fb = self._by_node(FB_USED, node_label)
        counts = self._count_by_node(SM_ACTIVE, node_label)

        samples = []
        for node, sm_value in sm.items():
            samples.append(
                GpuSample(
                    node=node,
                    sm_active_pct=round(sm_value * 100.0, 2),
                    gpu_util_pct=round(util.get(node, 0.0), 2),
                    fb_used_mib=round(fb.get(node, 0.0), 1),
                    gpu_count=counts.get(node, 1),
                )
            )
        return samples


def idle_nodes(
    samples: Iterable[GpuSample], threshold_pct: float
) -> list[str]:
    return [s.node for s in samples if s.sm_active_pct < threshold_pct]
