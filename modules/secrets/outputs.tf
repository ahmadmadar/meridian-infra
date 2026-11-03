output "secret_arns" {
  description = "Secret ARNs for the ECS task definition and its execution role policy (Session 3)."
  value       = { for k, s in aws_secretsmanager_secret.this : k => s.arn }

  # The ARNs exist before the values do. Without this, the ECS service can
  # launch a task that tries to read a secret with no AWSCURRENT version.
  depends_on = [
    aws_secretsmanager_secret_version.database_url,
    aws_secretsmanager_secret_version.mcp_key,
  ]
}
