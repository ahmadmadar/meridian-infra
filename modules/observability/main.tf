# CloudWatch for the POC. Started in Session 3a with just the app's log
# group, because the task's execution role and logging driver need it to
# exist; Session 5 adds alarms and the Budget alarm here.

resource "aws_cloudwatch_log_group" "app" {
  name = "/ecs/${var.name_prefix}/mcp-server"

  # Logs from a session-scoped POC aren't worth paying to keep; they're
  # deleted with the stack on destroy anyway.
  retention_in_days = 7
}
