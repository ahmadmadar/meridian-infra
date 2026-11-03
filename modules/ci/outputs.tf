output "user_name" {
  description = "For `aws iam create-access-key --user-name ...` at bring-up."
  value       = aws_iam_user.github_deploy.name
}
