output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "For the ALB and Fargate tasks (Session 3)."
  value       = [for s in aws_subnet.public : s.id]
}

output "private_subnet_ids" {
  description = "For the RDS subnet group (Session 2)."
  value       = [for s in aws_subnet.private : s.id]
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "app_security_group_id" {
  value = aws_security_group.app.id
}

output "db_security_group_id" {
  value = aws_security_group.db.id
}
