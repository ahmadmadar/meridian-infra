# No defaults: every value is passed explicitly from envs/poc.

variable "name_prefix" {
  description = "Prefix for resource names, e.g. \"meridian-poc\"."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for the DB subnet group (from the network module). Must span two AZs."
  type        = list(string)
}

variable "db_security_group_id" {
  description = "Security group allowing 5432 from the app tasks only (from the network module)."
  type        = string
}

variable "credentials_version" {
  description = "Bump to rotate the master password. Write-only values are only sent when this changes."
  type        = number
}
