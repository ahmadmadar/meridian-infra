# Deploy identity for the app repo's GitHub Actions pipeline.
# See docs/architecture.md, decision 11: GitHub OIDC is blocked by the
# free-plan SCP (iam:*Provider*), so CI uses an IAM user whose access key
# is created by hand at bring-up and deleted by `terraform destroy`.
#
# There is deliberately NO aws_iam_access_key here: that resource would
# write the secret key into Terraform state (decision 6).

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  # ARNs are built from names rather than referenced from modules/compute.
  # The ECR bootstrap (decision 9) applies with -target, and a reference to
  # the ECS service would pull the whole stack into that targeted apply.
  # These names must match modules/compute: ecr.tf (repository), ecs.tf
  # (cluster, service) and iam.tf (the two task roles).
  ecr_repository_arn = "arn:aws:ecr:${local.region}:${local.account_id}:repository/${var.name_prefix}/mcp-server"
  ecs_service_arn    = "arn:aws:ecs:${local.region}:${local.account_id}:service/${var.name_prefix}/${var.name_prefix}-mcp-server"
  task_role_arns = [
    "arn:aws:iam::${local.account_id}:role/${var.name_prefix}-task-execution",
    "arn:aws:iam::${local.account_id}:role/${var.name_prefix}-task",
  ]
}

resource "aws_iam_user" "github_deploy" {
  name = "${var.name_prefix}-github-deploy"

  # /managed/ is reserved by the account's SCP; /ci/ just groups machine users.
  path = "/ci/"

  # Not force_destroy: that makes the provider call iam:DeleteLoginProfile
  # (even when there is no login profile), which the free-plan SCP denies
  # (iam:*LoginProfile*), so every destroy failed on this user. Without it,
  # destroy only calls DeleteUser, which fails with DeleteConflict while the
  # access key exists. The runbook deletes the key (made by hand at bring-up)
  # before `plan -destroy`; if that step is skipped, destroy fails safely at
  # the end and can simply be re-run after deleting the key.
  force_destroy = false
}

data "aws_iam_policy_document" "github_deploy" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action has no resource-level scoping
  }

  statement {
    sid = "EcrPushAppImage"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [local.ecr_repository_arn]
  }

  # For the post-push "no CRITICAL findings" gate.
  statement {
    sid       = "EcrReadScan"
    actions   = ["ecr:DescribeImages", "ecr:DescribeImageScanFindings"]
    resources = [local.ecr_repository_arn]
  }

  statement {
    sid       = "EcsTaskDefinitions"
    actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
    resources = ["*"] # these actions have no resource-level scoping
  }

  statement {
    sid       = "EcsDeployService"
    actions   = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = [local.ecs_service_arn]
  }

  # Without this scoping, anyone holding the key could register a task
  # definition carrying any role in the account.
  statement {
    sid       = "PassTaskRolesToEcs"
    actions   = ["iam:PassRole"]
    resources = local.task_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_user_policy" "github_deploy" {
  name   = "push-image-and-deploy-service"
  user   = aws_iam_user.github_deploy.name
  policy = data.aws_iam_policy_document.github_deploy.json
}
