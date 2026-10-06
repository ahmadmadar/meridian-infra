# Internal Application Load Balancer. No public address: in Session 3b,
# CloudFront reaches it through a VPC origin (docs/architecture.md,
# decision 7), so HTTPS terminates at CloudFront and this hop stays on
# AWS's network.

resource "aws_lb" "app" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = true
  subnets            = var.private_subnet_ids
  security_groups    = [var.alb_security_group_id]

  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "app" {
  name        = "${var.name_prefix}-app"
  vpc_id      = var.vpc_id
  target_type = "ip" # Fargate tasks register by IP
  protocol    = "HTTP"
  port        = var.app_port

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # Default is 300s, which makes every deploy and destroy wait 5 minutes.
  deregistration_delay = 30
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  protocol          = "HTTP"
  port              = 80

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
