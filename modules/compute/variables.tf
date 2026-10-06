# No defaults: every value is passed explicitly from envs/poc.

variable "name_prefix" {
  description = "Prefix for resource names, e.g. \"meridian-poc\"."
  type        = string
}

variable "secret_arns" {
  description = "Secret ARNs the execution role may read and inject into the task (from the secrets module)."
  type        = map(string)
}

variable "log_group_arn" {
  description = "CloudWatch log group the task writes to (from the observability module)."
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch log group for the awslogs driver (from the observability module)."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  description = "Where the Fargate tasks run (public IP for outbound only)."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Where the internal ALB lives."
  type        = list(string)
}

variable "alb_security_group_id" {
  type = string
}

variable "app_security_group_id" {
  type = string
}

variable "app_port" {
  description = "Port the MCP server listens on inside the container."
  type        = number
}

variable "image_tag" {
  description = "ECR image tag to run (a git short SHA of the app repo)."
  type        = string
}
