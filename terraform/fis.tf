# Fault Injection Service, so the spot interruption in demo act 5 is a real
# one rather than a terminate call dressed up as a demo.
#
# The difference matters. TerminateInstances kills the box outright. A genuine
# spot interruption delivers a rebalance recommendation and a two-minute
# interruption notice to the EC2 metadata service, EventBridge mirrors both
# into Karpenter's interruption SQS queue, and Karpenter cordons and drains
# ahead of the reclaim. Only the second path proves the graceful-drain
# behaviour the NodePool was configured for.

data "aws_iam_policy_document" "fis_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["fis.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fis" {
  name               = "${local.name}-fis"
  assume_role_policy = data.aws_iam_policy_document.fis_assume.json
}

data "aws_iam_policy_document" "fis" {
  statement {
    sid       = "SpotInterruption"
    effect    = "Allow"
    actions   = ["ec2:SendSpotInstanceInterruptions"]
    resources = ["arn:aws:ec2:${var.aws_region}:*:instance/*"]

    # Scoped to this project's instances. An unscoped version of this policy
    # would let the experiment interrupt any spot instance in the account.
    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Project"
      values   = ["gpu-platform"]
    }
  }

  statement {
    sid       = "DescribeTargets"
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "fis" {
  name   = "spot-interruption"
  role   = aws_iam_role.fis.id
  policy = data.aws_iam_policy_document.fis.json
}

resource "aws_fis_experiment_template" "spot_interruption" {
  description = "Interrupt one gpu-platform spot GPU node"
  role_arn    = aws_iam_role.fis.arn

  # Required by the API. Nothing here should stop on an alarm, since the whole
  # point of the experiment is to cause the disruption.
  stop_condition {
    source = "none"
  }

  target {
    name           = "gpu-spot-nodes"
    resource_type  = "aws:ec2:spot-instance"
    selection_mode = "COUNT(1)"

    resource_tag {
      key   = "Project"
      value = "gpu-platform"
    }

    resource_tag {
      key   = "karpenter.sh/nodepool"
      value = "gpu"
    }
  }

  action {
    name      = "interrupt"
    action_id = "aws:ec2:send-spot-instance-interruptions"

    target {
      key   = "SpotInstances"
      value = "gpu-spot-nodes"
    }

    parameter {
      # The real notice period. Karpenter has these two minutes to cordon,
      # drain, and let Kueue requeue the workload.
      key   = "durationBeforeInterruption"
      value = "PT2M"
    }
  }

  tags = {
    Name = "${local.name}-spot-interruption"
  }
}
