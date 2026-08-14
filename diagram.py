"""Render the architecture diagram.

    python3 diagram.py    ->  docs/architecture.png
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EC2, ElasticKubernetesService
from diagrams.aws.database import Dynamodb
from diagrams.aws.devtools import XRay
from diagrams.aws.management import Cloudwatch
from diagrams.k8s.compute import Job, Pod
from diagrams.k8s.controlplane import CCM
from diagrams.onprem.monitoring import Grafana, Prometheus

GRAPH_ATTR = {
    "fontsize": "16",
    "bgcolor": "white",
    "pad": "0.6",
    "splines": "spline",
}

with Diagram(
    "GPU Platform: scheduling, density, and cost reclamation",
    filename="docs/architecture",
    show=False,
    direction="LR",
    graph_attr=GRAPH_ATTR,
):
    with Cluster("EKS control plane"):
        eks = ElasticKubernetesService("gpu-platform-dev")

    with Cluster("System nodes (t3.medium, on-demand)"):
        karpenter = CCM("Karpenter")
        kueue = CCM("Kueue")
        prom = Prometheus("Prometheus")
        grafana = Grafana("Grafana")
        collector = Pod("FinOps collector")

    with Cluster("GPU nodes (g4dn / g5, spot)"):
        gpu_node = EC2("Karpenter NodeClaim")
        dcgm = Pod("DCGM exporter")
        workload = Job("admitted job")

    with Cluster("Tenants"):
        team_a = Job("team-a LocalQueue")
        team_b = Job("team-b LocalQueue")

    ddb = Dynamodb("cost attribution")
    fis = XRay("FIS spot interruption")
    itn = Cloudwatch("interruption queue")

    # Admission path: tenants queue, Kueue admits to quota, Karpenter supplies
    # the hardware the admitted work needs.
    team_a >> Edge(label="submit") >> kueue
    team_b >> Edge(label="submit") >> kueue
    kueue >> Edge(label="admit to quota") >> workload
    kueue >> Edge(style="dashed", label="preempt") >> workload

    karpenter >> Edge(label="provision") >> gpu_node
    gpu_node >> workload
    gpu_node >> dcgm

    # Measurement path: SM occupancy, not the utilization gauge.
    dcgm >> Edge(label="SM_ACTIVE") >> prom
    prom >> collector
    prom >> grafana
    collector >> Edge(label="cost + waste") >> ddb

    # Reclamation path: the collector deletes the NodeClaim, not the Node,
    # because Karpenter would simply rebuild a deleted Node.
    collector >> Edge(style="dashed", color="firebrick", label="reap NodeClaim") >> karpenter

    # Interruption path.
    fis >> Edge(label="2-min notice") >> itn
    itn >> karpenter
    karpenter >> Edge(style="dotted", label="drain") >> gpu_node

    eks >> Edge(style="dotted") >> karpenter
