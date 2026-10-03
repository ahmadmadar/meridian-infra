# No defaults (fail-closed convention). Values come from terraform.tfvars,
# which is gitignored; see terraform.tfvars.example.

variable "region" {
  description = "AWS Region. The account is a new-experience project locked to us-east-2."
  type        = string

  validation {
    condition     = var.region == "us-east-2"
    error_message = "This account can only create resources in us-east-2."
  }
}

variable "aws_profile" {
  description = "AWS CLI profile, signed in via `aws login`."
  type        = string
}
