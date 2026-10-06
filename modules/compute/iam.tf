# Two roles per ECS task:
#   execution role: used by ECS to start the task (pull image, inject
#                   secrets, create the log stream). The app never sees it.
#   task role:      used by the app's own process at runtime. The MCP server
#                   calls no AWS APIs, so it only carries ECS Exec.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Both roles: only ECS tasks in this account and Region can assume them
# (confused-deputy protection). AWS's ECS docs scope SourceArn to
# account + Region, not to a single cluster or service.
data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

# ---------------------------------------------------------------------------
# Execution role. Scoped inline policy instead of the AWS-managed
# AmazonECSTaskExecutionRolePolicy, which allows pulling from every repo and
# writing to every log group, and doesn't cover secrets.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

data "aws_iam_policy_document" "execution" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action has no resource-level scoping
  }

  statement {
    sid = "EcrPullAppImage"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  statement {
    sid       = "WriteAppLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${var.log_group_arn}:*"]
  }

  # Secrets use the AWS-managed aws/secretsmanager key, so no kms:Decrypt.
  statement {
    sid       = "ReadAppSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = values(var.secret_arns)
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "pull-image-read-secrets-write-logs"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

# ---------------------------------------------------------------------------
# Task role: only what ECS Exec needs to open a shell into the container.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

data "aws_iam_policy_document" "task" {
  statement {
    sid = "EcsExec"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"] # these actions have no resource-level scoping
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "ecs-exec"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}
