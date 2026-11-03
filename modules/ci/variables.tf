# No defaults: every value is passed explicitly from envs/poc.

variable "name_prefix" {
  description = "Prefix for resource names, e.g. \"meridian-poc\". The policy ARNs are built from it (see main.tf)."
  type        = string
}
