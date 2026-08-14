"""DynamoDB persistence.

Same single-table shape as the cost dashboard's table so the existing analyzer
(z-score anomaly detection, linear regression forecast) and the React frontend
can read it without changes. It is a separate physical table on purpose: a
shared one would couple two repos through state and leave the guardrails
destroy-guard unable to distinguish a demo teardown from data loss.
"""

from __future__ import annotations

import logging
import time
from decimal import Decimal
from typing import Any

import boto3

log = logging.getLogger(__name__)

# Records are demo evidence, not a system of record. Fourteen days is long
# enough to show a trend and short enough that the table never accumulates
# cost of its own.
TTL_SECONDS = 14 * 24 * 3600


def _to_dynamo(value: Any) -> Any:
    """DynamoDB rejects float, so every number crosses as Decimal."""
    if isinstance(value, float):
        return Decimal(str(value))
    if isinstance(value, dict):
        return {k: _to_dynamo(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_to_dynamo(v) for v in value]
    return value


class CostStore:
    def __init__(self, table_name: str, region: str) -> None:
        self.table = boto3.resource("dynamodb", region_name=region).Table(table_name)

    def put_sample(self, record: dict[str, Any]) -> None:
        item = dict(record)
        item["expires_at"] = int(time.time()) + TTL_SECONDS
        self.table.put_item(Item=_to_dynamo(item))

    def put_samples(self, records: list[dict[str, Any]]) -> None:
        if not records:
            return
        expires = int(time.time()) + TTL_SECONDS
        with self.table.batch_writer() as batch:
            for record in records:
                item = dict(record)
                item["expires_at"] = expires
                batch.put_item(Item=_to_dynamo(item))
        log.info("wrote %d cost records", len(records))

    def put_reap_event(
        self,
        node: str,
        instance_id: str,
        instance_type: str,
        idle_minutes: int,
        hourly_rate: float,
        dry_run: bool,
    ) -> None:
        """Record what the reaper did, or would have done in dry-run.

        The dry-run rows are the interesting artifact: they are the evidence
        that the policy was watched before it was trusted to delete anything.
        """
        self.put_sample(
            {
                "pk": "REAP",
                "sk": f"{int(time.time())}#{node}",
                "record_type": "REAP",
                "node": node,
                "instance_id": instance_id,
                "instance_type": instance_type,
                "idle_minutes": idle_minutes,
                "hourly_rate_usd": hourly_rate,
                "projected_hourly_saving_usd": hourly_rate,
                "action": "would_terminate" if dry_run else "terminated",
                "dry_run": dry_run,
            }
        )
