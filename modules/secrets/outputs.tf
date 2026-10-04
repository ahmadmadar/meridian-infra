output "secret_arns" {
  description = "Secret ARNs for the ECS task definition and its execution role policy (Session 3)."
  value       = { for k, s in aws_secretsmanager_secret.this : k => s.arn }
}
