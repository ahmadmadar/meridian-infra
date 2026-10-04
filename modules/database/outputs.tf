output "address" {
  description = "DB hostname, only resolvable/reachable from inside the VPC."
  value       = aws_db_instance.main.address
}

output "port" {
  value = aws_db_instance.main.port
}

output "db_name" {
  value = aws_db_instance.main.db_name
}

output "username" {
  value = aws_db_instance.main.username
}

output "resource_id" {
  description = "Changes whenever the instance is replaced. Lets the secrets module re-write DATABASE_URL on replacement."
  value       = aws_db_instance.main.resource_id
}

output "master_password" {
  description = "Ephemeral: only usable within the same run, never stored."
  value       = ephemeral.random_password.master.result
  ephemeral   = true
}
