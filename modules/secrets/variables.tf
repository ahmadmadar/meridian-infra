# No defaults: every value is passed explicitly from envs/poc.

variable "name_prefix" {
  description = "Prefix for secret names, e.g. \"meridian-poc\"."
  type        = string
}

variable "database_url" {
  description = "Full Prisma DATABASE_URL including the master password."
  type        = string
  ephemeral   = true
}

variable "db_resource_id" {
  description = "RDS resource ID. When it changes (instance replaced), the DATABASE_URL secret is re-written."
  type        = string
}

variable "credentials_version" {
  description = "Bump to rotate every secret. Write-only values are only sent when this changes."
  type        = number
}
