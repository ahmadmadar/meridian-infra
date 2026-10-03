terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.67"
    }
  }

  # Local state on purpose; see docs/architecture.md, decision 4.
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = "meridian"
      Environment = "poc"
      ManagedBy   = "terraform"
    }
  }
}

locals {
  name_prefix = "meridian-poc"
}

module "network" {
  source = "../../modules/network"

  name_prefix          = local.name_prefix
  vpc_cidr             = "10.0.0.0/16"
  azs                  = ["us-east-2a", "us-east-2b"]
  public_subnet_cidrs  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24"]
  app_port             = 3001 # meridian-fde-enterprise-demo src/server.ts
}
