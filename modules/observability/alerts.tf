# Notification path for the alarms: alarm -> SNS topic -> email.
#
# The email subscription starts "pending confirmation": AWS mails a link
# and Terraform can't click it. Confirm once after every bring-up, or
# alarms fire into the void. (Budget alerts below email directly and
# don't need this.)

resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# CloudWatch must be allowed to publish to the topic. The default topic
# policy only trusts the account's own principals; alarms publish as the
# CloudWatch service, so the SourceAccount condition scopes it to us.
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "alerts_publish" {
  statement {
    sid       = "AllowCloudWatchAlarms"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_publish.json
}
