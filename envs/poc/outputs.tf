output "vpc_id" {
  value = module.network.vpc_id
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

output "security_group_ids" {
  value = {
    alb = module.network.alb_security_group_id
    app = module.network.app_security_group_id
    db  = module.network.db_security_group_id
  }
}

output "db_address" {
  description = "Private hostname; reachable only from inside the VPC."
  value       = module.database.address
}

output "secret_arns" {
  value = module.secrets.secret_arns
}

output "ecr_repository_url" {
  value = module.compute.ecr_repository_url
}

output "ecs" {
  description = "Names for aws ecs execute-command / run-task."
  value = {
    cluster         = module.compute.cluster_name
    service         = module.compute.service_name
    task_definition = module.compute.task_definition_arn
  }
}

output "alb_dns_name" {
  description = "Internal ALB; resolves to private IPs only."
  value       = module.compute.alb_dns_name
}
