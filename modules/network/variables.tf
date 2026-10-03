# No defaults: every value is passed explicitly from envs/poc, so the
# network shape is visible in one place rather than split across files.

variable "name_prefix" {
  description = "Prefix for resource Name tags, e.g. \"meridian-poc\"."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "azs" {
  description = "Availability Zones to spread subnets across. RDS needs at least two."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2
    error_message = "At least two AZs are required (RDS subnet groups and ALBs both need two)."
  }
}

variable "public_subnet_cidrs" {
  description = "One CIDR per AZ for the public subnets (ALB + Fargate tasks)."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "One CIDR per AZ for the private subnets (RDS)."
  type        = list(string)
}

variable "app_port" {
  description = "Port the MCP server container listens on."
  type        = number
}
