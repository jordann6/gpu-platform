data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name = "${var.cluster_name}-${var.environment}"

  # Three AZs. GPU spot capacity for g4dn is uneven across zones, and a
  # single-AZ NodePool is the most common reason a GPU pod sits Pending
  # forever with no obvious error.
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

module "vpc" {
  # checkov:skip=CKV_TF_1:Registry modules are pinned by semantic version,
  #   which the registry protocol makes immutable. Commit-hash pinning
  #   applies to git sources; it is not expressible for a registry source.
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i + 48)]

  # One NAT gateway, not one per AZ. The guardrails NAT cost rule warns on
  # these; a demo cluster does not need zonal NAT redundancy and three of them
  # would cost more than the GPUs.
  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Karpenter discovers subnets by this tag rather than by id.
    "karpenter.sh/discovery" = local.name
  }
}
