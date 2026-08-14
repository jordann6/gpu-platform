"""Collection loop: sample utilization, attribute cost, reap what is idle."""

from __future__ import annotations

import logging
import signal
import sys
import time
from datetime import datetime, timezone

from .config import Config
from .pricing import Pricing, interval_cost, wasted_cost
from .prom import Prometheus, PrometheusError
from .reaper import Reaper
from .store import CostStore

logging.basicConfig(
    level=logging.INFO,
    format='{"ts":"%(asctime)s","level":"%(levelname)s","logger":"%(name)s","msg":"%(message)s"}',
)
log = logging.getLogger("finops.collector")

_running = True


def _stop(signum, _frame):
    global _running
    log.info("received signal %s, shutting down", signum)
    _running = False


def tick(cfg: Config, prom: Prometheus, pricing: Pricing, store: CostStore, reaper: Reaper) -> None:
    try:
        samples = prom.sample()
    except PrometheusError as exc:
        # Normal before the first GPU node exists. Not an error worth crashing
        # the loop over.
        log.info("no GPU samples yet: %s", exc)
        return

    if not samples:
        return

    nodes = pricing.describe_gpu_nodes([s.node for s in samples])
    now = datetime.now(timezone.utc)
    stamp = now.isoformat()

    records = []
    for sample in samples:
        info = nodes.get(sample.node)
        if info is None:
            log.warning("no EC2 match for node %s, skipping cost attribution", sample.node)
            continue

        rate = pricing.hourly_rate(info)
        spend = interval_cost(rate, cfg.interval_seconds)
        waste = wasted_cost(spend, sample.sm_active_pct)

        records.append(
            {
                "pk": f"GPU#{info.instance_id}",
                "sk": stamp,
                "record_type": "GPU_SAMPLE",
                "node": sample.node,
                "instance_type": info.instance_type,
                "lifecycle": info.lifecycle,
                "availability_zone": info.availability_zone,
                "gpu_count": sample.gpu_count,
                "sm_active_pct": sample.sm_active_pct,
                "gpu_util_pct": sample.gpu_util_pct,
                "fb_used_mib": sample.fb_used_mib,
                "hourly_rate_usd": rate,
                "interval_seconds": cfg.interval_seconds,
                "cost_usd": round(spend, 8),
                "wasted_cost_usd": waste,
            }
        )

        is_idle = sample.sm_active_pct < cfg.idle_threshold_pct
        streak = reaper.record(sample.node, is_idle)

        if is_idle and streak >= reaper.samples_required:
            eligible, reason = reaper.eligible(sample.node)
            if eligible:
                acted = reaper.reap(sample.node)
                store.put_reap_event(
                    node=sample.node,
                    instance_id=info.instance_id,
                    instance_type=info.instance_type,
                    idle_minutes=cfg.idle_minutes,
                    hourly_rate=rate,
                    dry_run=not acted,
                )
            else:
                log.info("node %s idle but held: %s", sample.node, reason)

    store.put_samples(records)

    total = sum(r["cost_usd"] for r in records)
    burned = sum(r["wasted_cost_usd"] for r in records)
    log.info(
        "sampled %d GPU nodes, interval spend $%.6f, of which $%.6f bought no computation",
        len(records),
        total,
        burned,
    )


def main() -> int:
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    cfg = Config.from_env()
    log.info(
        "starting collector: interval=%ss idle=<%s%% for %smin (%s samples) dry_run=%s",
        cfg.interval_seconds,
        cfg.idle_threshold_pct,
        cfg.idle_minutes,
        cfg.samples_required,
        cfg.dry_run,
    )

    prom = Prometheus(cfg.prometheus_url)
    pricing = Pricing(cfg.region)
    store = CostStore(cfg.table_name, cfg.region)
    reaper = Reaper(samples_required=cfg.samples_required, dry_run=cfg.dry_run)

    while _running:
        started = time.monotonic()
        try:
            tick(cfg, prom, pricing, store, reaper)
        except Exception:
            # One bad scrape must not take down cost collection for the fleet.
            log.exception("tick failed")

        elapsed = time.monotonic() - started
        time.sleep(max(0.0, cfg.interval_seconds - elapsed))

    return 0


if __name__ == "__main__":
    sys.exit(main())
