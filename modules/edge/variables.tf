# No defaults: every value is passed explicitly from envs/poc.

variable "name_prefix" {
  description = "Prefix for resource names, e.g. \"meridian-poc\"."
  type        = string
}

variable "vpc_id" {
  description = "VPC the ALB is in; where AWS creates the VPC origin's security group."
  type        = string
}

variable "alb_arn" {
  description = "The internal ALB CloudFront reaches through the VPC origin (from the compute module)."
  type        = string
}

variable "alb_dns_name" {
  description = "Internal ALB DNS name, used as the origin's domain (from the compute module)."
  type        = string
}

variable "alb_listener_port" {
  description = "Port of the ALB's HTTP listener."
  type        = number
}

variable "alb_security_group_id" {
  description = "ALB security group that gets the from-CloudFront ingress rule (from the network module)."
  type        = string
}
