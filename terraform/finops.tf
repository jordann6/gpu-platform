# Own table, same single-table schema as the cost dashboard's. Sharing the
# dashboard's table would couple two repos through state and make the
# guardrails destroy-guard unable to tell a demo teardown from data loss.
resource "aws_dynamodb_table" "gpu_costs" {
  # checkov:skip=CKV_AWS_28:Point-in-time recovery is off deliberately. Every
  #   record carries a 14-day TTL and is demo evidence regenerated on each
  #   run, not a system of record. PITR would bill continuously for data that
  #   is designed to expire.
  # checkov:skip=CKV_AWS_119:A customer-managed CMK is declined on teardown
  #   cost, not on principle. KMS keys cannot be deleted immediately; they
  #   linger 7 to 30 days after destroy, which is exactly the residue the
  #   landing-zone teardown had to account for. AWS-owned encryption covers
  #   TTL'd demo data.
  name         = "${local.name}-costs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = false
  }

  server_side_encryption {
    enabled = true
  }
}

resource "aws_ecr_repository" "collector" {
  name = "${local.name}/finops-collector"

  # Immutable. Images are tagged with the git SHA, so a tag names exactly one
  # build forever and a rollback is unambiguous. This also makes a re-push of
  # the same tag fail loudly rather than silently changing what is deployed.
  image_tag_mutability = "IMMUTABLE"

  # Demo repository; the teardown should not need a manual image purge first.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    # AWS-managed ECR key. Same reasoning as the DynamoDB table: a CMK would
    # outlive the destroy by 7 to 30 days for no benefit on public images.
    encryption_type = "KMS"
  }
}

data "aws_iam_policy_document" "collector_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "collector" {
  name               = "${local.name}-finops-collector"
  assume_role_policy = data.aws_iam_policy_document.collector_assume.json
}

data "aws_iam_policy_document" "collector" {
  statement {
    sid    = "CostRecords"
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:Query",
      "dynamodb:GetItem",
    ]
    resources = [aws_dynamodb_table.gpu_costs.arn]
  }

  statement {
    sid    = "RateLookup"
    effect = "Allow"
    actions = [
      # Pricing API is not resource-scopable; it is a read-only global catalog.
      "pricing:GetProducts",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypes",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "collector" {
  name   = "finops-collector"
  role   = aws_iam_role.collector.id
  policy = data.aws_iam_policy_document.collector.json
}

resource "kubernetes_namespace" "finops" {
  metadata {
    name = "finops"
  }
}

resource "kubernetes_service_account" "collector" {
  metadata {
    name      = "finops-collector"
    namespace = kubernetes_namespace.finops.metadata[0].name
  }
}

resource "aws_eks_pod_identity_association" "collector" {
  cluster_name    = module.eks.cluster_name
  namespace       = kubernetes_namespace.finops.metadata[0].name
  service_account = kubernetes_service_account.collector.metadata[0].name
  role_arn        = aws_iam_role.collector.arn
}

# The reaper half needs to cordon nodes and delete the NodeClaim that backs
# them. Deleting the Node alone is not enough: Karpenter would simply
# reconcile a replacement.
resource "kubernetes_cluster_role" "reaper" {
  metadata {
    name = "finops-reaper"
  }

  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list", "watch", "patch", "update"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["karpenter.sh"]
    resources  = ["nodeclaims"]
    verbs      = ["get", "list", "watch", "delete"]
  }

  rule {
    api_groups = ["kueue.x-k8s.io"]
    resources  = ["workloads"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "reaper" {
  metadata {
    name = "finops-reaper"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.reaper.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.collector.metadata[0].name
    namespace = kubernetes_namespace.finops.metadata[0].name
  }
}
