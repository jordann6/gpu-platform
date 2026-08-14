"""Runtime configuration, all of it injected by the Terraform deployment."""

from __future__ import annotations

import os
from dataclasses import dataclass


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Config:
    region: str
    prometheus_url: str
    table_name: str
    idle_threshold_pct: float
    idle_minutes: int
    dry_run: bool
    interval_seconds: int

    @classmethod
    def from_env(cls) -> Config:
        return cls(
            region=os.environ.get("AWS_REGION", "us-east-1"),
            prometheus_url=os.environ["PROMETHEUS_URL"],
            table_name=os.environ["TABLE_NAME"],
            idle_threshold_pct=float(os.environ.get("IDLE_THRESHOLD_PCT", "5")),
            idle_minutes=int(os.environ.get("IDLE_MINUTES", "30")),
            dry_run=_env_bool("DRY_RUN", True),
            interval_seconds=int(os.environ.get("INTERVAL_SECONDS", "60")),
        )

    @property
    def samples_required(self) -> int:
        """How many consecutive idle samples justify reaping a node."""
        return max(1, (self.idle_minutes * 60) // self.interval_seconds)
