# Secrets Manager entries injected into the ECS task in Session 3.
#
# Values are ephemeral and written through secret_string_wo, so neither the
# DB password nor the MCP keys ever land in Terraform state or plan output.

ephemeral "random_password" "mcp_key" {
  for_each = toset(["agent", "dashboard"])

  length  = 48
  special = false
}

locals {
  secret_names = toset(["database-url", "mcp-key-agent", "mcp-key-dashboard"])
}

resource "aws_secretsmanager_secret" "this" {
  for_each = local.secret_names

  name                    = "${var.name_prefix}/${each.key}"
  recovery_window_in_days = 0 # destroy -> re-apply can reuse the name immediately
}

# Tracks the DB's identity. If RDS is replaced it gets a new password, so the
# DATABASE_URL version must be re-created too, even though
# credentials_version hasn't changed.
resource "terraform_data" "db_identity" {
  input = var.db_resource_id
}

resource "aws_secretsmanager_secret_version" "database_url" {
  secret_id                = aws_secretsmanager_secret.this["database-url"].id
  secret_string_wo         = var.database_url
  secret_string_wo_version = var.credentials_version

  lifecycle {
    replace_triggered_by = [terraform_data.db_identity]
  }
}

resource "aws_secretsmanager_secret_version" "mcp_key" {
  for_each = toset(["agent", "dashboard"])

  secret_id                = aws_secretsmanager_secret.this["mcp-key-${each.key}"].id
  secret_string_wo         = ephemeral.random_password.mcp_key[each.key].result
  secret_string_wo_version = var.credentials_version
}
