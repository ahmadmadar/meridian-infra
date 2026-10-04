# RDS Postgres, private subnets only. See docs/architecture.md, decision 3.
#
# The master password is ephemeral: generated per run and passed through a
# write-only argument, so it never lands in Terraform state or plan output.

ephemeral "random_password" "master" {
  length  = 32
  special = false # alphanumeric: valid for RDS and needs no URL-encoding in DATABASE_URL
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.name_prefix}-db"
  subnet_ids = var.private_subnet_ids
}

resource "aws_db_instance" "main" {
  identifier     = "${var.name_prefix}-db"
  engine         = "postgres"
  engine_version = "16"           # same major as local docker postgres:16
  instance_class = "db.t4g.micro" # free plan allows only t3/t4g micro

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true # AWS-managed KMS key

  db_name             = "meridian"
  username            = "meridian"
  password_wo         = ephemeral.random_password.master.result
  password_wo_version = var.credentials_version

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.db_security_group_id]
  publicly_accessible    = false
  multi_az               = false

  # POC destroyed every session: no automated backups, no final snapshot
  # left behind to bill after destroy.
  backup_retention_period = 0
  skip_final_snapshot     = true
  apply_immediately       = true
}
