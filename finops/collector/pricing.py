"""Per-second cost attribution for GPU nodes.

Cost Explorer cannot do this job. It reports at daily granularity and lags 8 to
24 hours, so a three-hour GPU demo never appears in it while the demo is
running, and even after the lag a whole day is one row. Accelerators are rented
by the second and idle for minutes at a time, so the unit of waste is smaller
than the unit Cost Explorer can see.

So the rate comes from the Pricing API for on-demand and from the spot price
history for spot, and the quantity comes from observed instance-seconds.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass

import boto3

log = logging.getLogger(__name__)

# The Pricing API only has endpoints in a few regions and its catalog is
# global, so it is always called in us-east-1 regardless of cluster region.
PRICING_ENDPOINT_REGION = "us-east-1"

REGION_TO_LOCATION = {
    "us-east-1": "US East (N. Virginia)",
    "us-east-2": "US East (Ohio)",
    "us-west-2": "US West (Oregon)",
    "eu-west-1": "EU (Ireland)",
}


@dataclass(frozen=True)
class NodeInfo:
    node: str
    instance_id: str
    instance_type: str
    lifecycle: str  # "spot" or "on-demand"
    availability_zone: str


class Pricing:
    def __init__(self, region: str) -> None:
        self.region = region
        self.ec2 = boto3.client("ec2", region_name=region)
        self.pricing = boto3.client("pricing", region_name=PRICING_ENDPOINT_REGION)
        self._on_demand_cache: dict[str, float] = {}
        self._spot_cache: dict[tuple[str, str], float] = {}

    def describe_gpu_nodes(self, node_names: list[str]) -> dict[str, NodeInfo]:
        """Map Kubernetes node names to the EC2 facts needed for billing.

        Karpenter names nodes after their private DNS name, so that is the
        filter rather than a tag lookup.
        """
        if not node_names:
            return {}

        out: dict[str, NodeInfo] = {}
        paginator = self.ec2.get_paginator("describe_instances")
        pages = paginator.paginate(
            Filters=[
                {"Name": "private-dns-name", "Values": node_names},
                {"Name": "instance-state-name", "Values": ["running"]},
            ]
        )

        for page in pages:
            for reservation in page["Reservations"]:
                for inst in reservation["Instances"]:
                    name = inst.get("PrivateDnsName", "")
                    if not name:
                        continue
                    out[name] = NodeInfo(
                        node=name,
                        instance_id=inst["InstanceId"],
                        instance_type=inst["InstanceType"],
                        # InstanceLifecycle is absent entirely on on-demand.
                        lifecycle=inst.get("InstanceLifecycle", "on-demand"),
                        availability_zone=inst["Placement"]["AvailabilityZone"],
                    )
        return out

    def on_demand_hourly(self, instance_type: str) -> float:
        if instance_type in self._on_demand_cache:
            return self._on_demand_cache[instance_type]

        location = REGION_TO_LOCATION.get(self.region)
        if location is None:
            raise ValueError(
                f"no Pricing API location name mapped for region {self.region}"
            )

        resp = self.pricing.get_products(
            ServiceCode="AmazonEC2",
            Filters=[
                {"Type": "TERM_MATCH", "Field": "instanceType", "Value": instance_type},
                {"Type": "TERM_MATCH", "Field": "location", "Value": location},
                {"Type": "TERM_MATCH", "Field": "tenancy", "Value": "Shared"},
                {"Type": "TERM_MATCH", "Field": "operatingSystem", "Value": "Linux"},
                {"Type": "TERM_MATCH", "Field": "preInstalledSw", "Value": "NA"},
                # Without capacitystatus the catalog also returns reserved and
                # capacity-block SKUs and the first match is arbitrary.
                {"Type": "TERM_MATCH", "Field": "capacitystatus", "Value": "Used"},
            ],
            MaxResults=1,
        )

        if not resp["PriceList"]:
            raise ValueError(f"no on-demand price found for {instance_type}")

        product = json.loads(resp["PriceList"][0])
        terms = product["terms"]["OnDemand"]
        offer = next(iter(terms.values()))
        dimension = next(iter(offer["priceDimensions"].values()))
        rate = float(dimension["pricePerUnit"]["USD"])

        self._on_demand_cache[instance_type] = rate
        return rate

    def spot_hourly(self, instance_type: str, availability_zone: str) -> float:
        key = (instance_type, availability_zone)
        if key in self._spot_cache:
            return self._spot_cache[key]

        resp = self.ec2.describe_spot_price_history(
            InstanceTypes=[instance_type],
            ProductDescriptions=["Linux/UNIX"],
            AvailabilityZone=availability_zone,
            MaxResults=1,
        )
        history = resp.get("SpotPriceHistory", [])
        if not history:
            log.warning(
                "no spot history for %s in %s, falling back to on-demand rate",
                instance_type,
                availability_zone,
            )
            return self.on_demand_hourly(instance_type)

        rate = float(history[0]["SpotPrice"])
        self._spot_cache[key] = rate
        return rate

    def hourly_rate(self, info: NodeInfo) -> float:
        if info.lifecycle == "spot":
            return self.spot_hourly(info.instance_type, info.availability_zone)
        return self.on_demand_hourly(info.instance_type)


def interval_cost(hourly_rate: float, interval_seconds: int) -> float:
    """Cost of holding an instance for one collection interval."""
    return hourly_rate * (interval_seconds / 3600.0)


def wasted_cost(interval_cost_usd: float, sm_active_pct: float) -> float:
    """The portion of the interval's spend that bought no computation.

    Deliberately linear. Fractional SM occupancy does not map to fractional
    dollars in any rigorous way, since you rent the whole card either way. It
    is a waste indicator for ranking nodes, not an accounting figure, and the
    README says so.
    """
    idle_fraction = max(0.0, 1.0 - (sm_active_pct / 100.0))
    return round(interval_cost_usd * idle_fraction, 8)
