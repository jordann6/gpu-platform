module "eks" {
  # checkov:skip=CKV_TF_1:Registry module pinned by immutable semantic version.
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = local.name
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  # The identity running terraform gets cluster-admin, otherwise the helm and
  # kubectl providers in this same apply cannot authenticate.
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
    eks-pod-identity-agent = { most_recent = true }
  }

  # System nodes only. Every GPU node comes from Karpenter instead, so the
  # managed node group stays small, on-demand and boring.
  eks_managed_node_groups = {
    system = {
      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"
      min_size       = 2
      max_size       = 3
      desired_size   = 2

      labels = {
        "workload-class" = "system"
      }
    }
  }

  node_security_group_tags = {
    "karpenter.sh/discovery" = local.name
  }

  # DCGM exporter scrapes on 9400 and Prometheus lives on a system node, so
  # node-to-node traffic on that port has to be allowed explicitly.
  node_security_group_additional_rules = {
    dcgm_scrape = {
      description = "Prometheus scrape of DCGM exporter"
      protocol    = "tcp"
      from_port   = 9400
      to_port     = 9400
      type        = "ingress"
      self        = true
    }
  }
}
