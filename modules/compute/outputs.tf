output "ecr_repository_url" {
  description = "Push target: <account>.dkr.ecr.<region>.amazonaws.com/meridian-poc/mcp-server"
  value       = aws_ecr_repository.app.repository_url
}

output "cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "service_name" {
  value = aws_ecs_service.app.name
}

output "task_definition_arn" {
  description = "For one-off tasks (e.g. seeding) via `aws ecs run-task`."
  value       = aws_ecs_task_definition.app.arn
}

output "alb_arn" {
  description = "For the CloudFront VPC origin in Session 3b."
  value       = aws_lb.app.arn
}

output "alb_listener_port" {
  description = "For the CloudFront VPC origin and the ALB's ingress rule."
  value       = aws_lb_listener.http.port
}

output "alb_dns_name" {
  description = "Internal DNS name; resolves only to private IPs."
  value       = aws_lb.app.dns_name
}

output "target_group_arn" {
  value = aws_lb_target_group.app.arn
}
