# No defaults: every value is passed explicitly from envs/poc.

variable "name_prefix" {
  description = "Prefix for resource names, e.g. \"meridian-poc\"."
  type        = string
}
