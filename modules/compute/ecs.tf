# ECS on Fargate: one task running the MCP server, behind the internal ALB.
# See docs/architecture.md, decisions 1 and 2.

locals {
  container_name = "mcp-server"
}

resource "aws_ecs_cluster" "main" {
  name = var.name_prefix

  # Paid per-task metrics; monitoring is decided in Session 5.
  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.name_prefix}-mcp-server"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256 # 0.25 vCPU
  memory                   = 512 # MB, same as the Render free instance

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task.arn

  # The image is built on Apple Silicon; Graviton is also ~20% cheaper.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
      essential = true

      portMappings = [
        { containerPort = var.app_port, protocol = "tcp" }
      ]

      environment = [
        { name = "NODE_ENV", value = "production" }, # JSON logs, not pino-pretty
        { name = "PORT", value = tostring(var.app_port) },
        { name = "LOG_LEVEL", value = "info" },
      ]

      # Fetched by the execution role at startup and injected as env vars.
      # Only the ARNs are here; the values never touch the task definition.
      secrets = [
        { name = "DATABASE_URL", valueFrom = var.secret_arns["database-url"] },
        { name = "MCP_KEY_AGENT", valueFrom = var.secret_arns["mcp-key-agent"] },
        { name = "MCP_KEY_DASHBOARD", valueFrom = var.secret_arns["mcp-key-dashboard"] },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = var.log_group_name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = "ecs"
        }
      }

      # Recommended for ECS Exec: an init process reaps exec'd shells.
      linuxParameters = {
        initProcessEnabled = true
      }
    }
  ])
}

resource "aws_ecs_service" "app" {
  name             = "${var.name_prefix}-mcp-server"
  cluster          = aws_ecs_cluster.main.id
  task_definition  = aws_ecs_task_definition.app.arn
  desired_count    = 1
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  enable_execute_command = true

  # Public subnets + public IP for outbound only (ECR, Secrets Manager,
  # Logs) without a NAT Gateway. Inbound is the app SG: ALB only.
  network_configuration {
    subnets          = var.public_subnet_ids
    security_groups  = [var.app_security_group_id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = local.container_name
    container_port   = var.app_port
  }

  # The container runs `prisma migrate deploy` before listening; don't let
  # the ALB health check kill it mid-migration.
  health_check_grace_period_seconds = 90

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # `apply` only finishes once the task is running and healthy.
  wait_for_steady_state = true

  # The target group must be attached to the ALB before a service uses it.
  depends_on = [aws_lb_listener.http]
}
