# Private image registry for the MCP server.
#
# Applied on its own first (-target) on every bring-up: the ECS service
# needs an image to exist before it can start. See CLAUDE.md for the order.

resource "aws_ecr_repository" "app" {
  name = "${var.name_prefix}/mcp-server"

  # Tags are git SHAs; a tag can never be re-pointed at a different image.
  image_tag_mutability = "IMMUTABLE"

  # Repo-level basic scanning (free). The registry-level setting would be
  # account-wide and outlive `terraform destroy`; this goes with the repo.
  image_scanning_configuration {
    scan_on_push = true
  }

  # Destroy between sessions: delete the repo even if it still holds images.
  force_delete = true
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images (failed or superseded pushes)"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the 5 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = { type = "expire" }
      },
    ]
  })
}
