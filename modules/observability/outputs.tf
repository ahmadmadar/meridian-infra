output "app_log_group_name" {
  description = "For the task definition's awslogs driver."
  value       = aws_cloudwatch_log_group.app.name
}

output "app_log_group_arn" {
  description = "For the execution role's logs permissions."
  value       = aws_cloudwatch_log_group.app.arn
}
