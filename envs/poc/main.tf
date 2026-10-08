terraform {
  required_version = ">= 1.11" # write-only arguments (password_wo, secret_string_wo)

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.67"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7" # ephemeral random_password
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

  # Bump to rotate the DB password and both MCP keys in one apply.
  # Write-only values are only sent to AWS when this number changes.
  credentials_version = 1

  app_port = 3001 # meridian-fde-enterprise-demo src/server.ts
}

module "network" {
  source = "../../modules/network"

  name_prefix          = local.name_prefix
  vpc_cidr             = "10.0.0.0/16"
  azs                  = ["us-east-2a", "us-east-2b"]
  public_subnet_cidrs  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24"]
  app_port             = local.app_port
}

module "database" {
  source = "../../modules/database"

  name_prefix          = local.name_prefix
  private_subnet_ids   = module.network.private_subnet_ids
  db_security_group_id = module.network.db_security_group_id
  credentials_version  = local.credentials_version
}

module "secrets" {
  source = "../../modules/secrets"

  name_prefix = local.name_prefix
  # Prisma connection string, matching the app's .env.example shape.
  # RDS Postgres 16 enforces SSL (rds.force_ssl = 1), hence sslmode=require.
  database_url        = "postgresql://${module.database.username}:${module.database.master_password}@${module.database.address}:${module.database.port}/${module.database.db_name}?schema=public&sslmode=require"
  db_resource_id      = module.database.resource_id
  credentials_version = local.credentials_version
}

module "observability" {
  source = "../../modules/observability"

  name_prefix = local.name_prefix
}

module "compute" {
  source = "../../modules/compute"

  name_prefix = local.name_prefix
  image_tag   = var.image_tag
  app_port    = local.app_port

  vpc_id                = module.network.vpc_id
  public_subnet_ids     = module.network.public_subnet_ids
  private_subnet_ids    = module.network.private_subnet_ids
  alb_security_group_id = module.network.alb_security_group_id
  app_security_group_id = module.network.app_security_group_id

  secret_arns    = module.secrets.secret_arns
  log_group_arn  = module.observability.app_log_group_arn
  log_group_name = module.observability.app_log_group_name
}

module "edge" {
  source = "../../modules/edge"

  name_prefix = local.name_prefix

  vpc_id                = module.network.vpc_id
  alb_security_group_id = module.network.alb_security_group_id
  alb_arn               = module.compute.alb_arn
  alb_dns_name          = module.compute.alb_dns_name
  alb_listener_port     = module.compute.alb_listener_port
}
