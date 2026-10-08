locals {
  public_subnets  = { for i, az in var.azs : az => var.public_subnet_cidrs[i] }
  private_subnets = { for i, az in var.azs : az => var.private_subnet_cidrs[i] }
}

# ---------------------------------------------------------------------------
# VPC + internet access
# ---------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.name_prefix }
}

# The VPC's only path to the internet. Only the public route table uses it.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = var.name_prefix }
}

# ---------------------------------------------------------------------------
# Subnets. Keyed by AZ so adding/removing an AZ never renumbers the others.
# ---------------------------------------------------------------------------

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = each.value

  # Fargate tasks request a public IP explicitly in their own config
  # (Session 3); nothing else launched here gets one by default.
  map_public_ip_on_launch = false

  tags = { Name = "${var.name_prefix}-public-${each.key}" }
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false

  tags = { Name = "${var.name_prefix}-private-${each.key}" }
}

# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.name_prefix}-public" }
}

# Deliberately empty: only the implicit VPC-local route. Explicit rather
# than relying on the VPC's main route table, so a route added there later
# can't silently expose the database subnets.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.name_prefix}-private" }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# Security groups: ALB -> app -> db, each tier only reachable from the one
# in front of it, referenced by security group ID rather than IP range.
# ---------------------------------------------------------------------------

# Adopting the default SG with no rules strips its allow-all rules, so
# anything accidentally placed in it is isolated.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.name_prefix}-default-locked" }
}

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "Internal ALB: inbound only from the CloudFront VPC origin, forwards only to the app"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.name_prefix}-alb" }
}

resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app"
  description = "Fargate tasks: inbound only from the ALB"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.name_prefix}-app" }
}

resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db"
  description = "RDS Postgres: inbound only from the app tasks"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.name_prefix}-db" }
}

# --- ALB ---

# No ingress rule here. The only way in is from CloudFront's VPC origin,
# and that rule lives in modules/edge: it references a security group
# AWS creates with the VPC origin, which needs the ALB from compute, so
# defining it here would make network depend on compute (a cycle).
# See docs/architecture.md, decision 7.

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to app tasks only"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
}

# --- App (Fargate tasks) ---

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "From the ALB only"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
}

resource "aws_vpc_security_group_egress_rule" "app_https_out" {
  security_group_id = aws_security_group.app.id
  description       = "ECR image pulls, Secrets Manager, CloudWatch Logs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "Postgres to RDS only"
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

# --- DB: inbound from app only, no egress rules at all ---

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "Postgres from app tasks only"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
