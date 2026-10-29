terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

locals {
  name      = "server-monitor"
  namespace = "ServerMonitor"
  targets   = { for t in var.targets : t.name => t }
}

# ---------------------------------------------------------------------------
# SNS: alert topic + email subscription
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------------------------------------------------------------------------
# DynamoDB: check history. One item per target per check, auto-deleted by TTL.
# "ts" is used instead of "timestamp" because timestamp is a reserved word.
# Provisioned capacity (small) stays inside the always-free allowance.
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "history" {
  name           = "${local.name}-history"
  billing_mode   = "PROVISIONED"
  read_capacity  = 10
  write_capacity = 5
  hash_key       = "target"
  range_key      = "ts"

  attribute {
    name = "target"
    type = "S"
  }

  attribute {
    name = "ts"
    type = "N"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}

# ---------------------------------------------------------------------------
# S3: private bucket holding status.json (CloudFront will serve it in step 3)
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "status" {
  bucket        = "${local.name}-status-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "status" {
  bucket                  = aws_s3_bucket.status.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# IAM: Lambda can write logs, publish metrics, use the table and write status.json
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "checker" {
  name               = "${local.name}-checker"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.checker.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "metrics" {
  statement {
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [local.namespace]
    }
  }
}

resource "aws_iam_role_policy" "metrics" {
  name   = "put-metrics"
  role   = aws_iam_role.checker.id
  policy = data.aws_iam_policy_document.metrics.json
}

data "aws_iam_policy_document" "storage" {
  statement {
    actions   = ["dynamodb:PutItem", "dynamodb:Query"]
    resources = [aws_dynamodb_table.history.arn]
  }

  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.status.arn}/status.json"]
  }
}

resource "aws_iam_role_policy" "storage" {
  name   = "history-and-status"
  role   = aws_iam_role.checker.id
  policy = data.aws_iam_policy_document.storage.json
}

# ---------------------------------------------------------------------------
# Lambda: health checker
# ---------------------------------------------------------------------------
data "archive_file" "checker" {
  type        = "zip"
  source_file = "${path.module}/lambda/checker.py"
  output_path = "${path.module}/build/checker.zip"
}

resource "aws_lambda_function" "checker" {
  function_name    = "${local.name}-checker"
  role             = aws_iam_role.checker.arn
  runtime          = "python3.12"
  handler          = "checker.handler"
  filename         = data.archive_file.checker.output_path
  source_code_hash = data.archive_file.checker.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      TARGETS                   = jsonencode(var.targets)
      NAMESPACE                 = local.namespace
      TABLE_NAME                = aws_dynamodb_table.history.name
      BUCKET_NAME               = aws_s3_bucket.status.bucket
      RETENTION_DAYS            = tostring(var.retention_days)
      AVAILABILITY_WINDOW_HOURS = tostring(var.availability_window_hours)
    }
  }
}

resource "aws_cloudwatch_log_group" "checker" {
  name              = "/aws/lambda/${aws_lambda_function.checker.function_name}"
  retention_in_days = 7
}

# ---------------------------------------------------------------------------
# EventBridge: run the checker every minute
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "every_minute" {
  name                = "${local.name}-every-minute"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "checker" {
  rule = aws_cloudwatch_event_rule.every_minute.name
  arn  = aws_lambda_function.checker.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.checker.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.every_minute.arn
}

# ---------------------------------------------------------------------------
# Down alarm per target: 2 failures out of the last 3 checks
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "down" {
  for_each = local.targets

  alarm_name          = "${local.name}-down-${each.key}"
  alarm_description   = "${each.key} (${each.value.url}) failed 2 of the last 3 checks"
  namespace           = local.namespace
  metric_name         = "Up"
  dimensions          = { Target = each.key }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "lambda_name" {
  value = aws_lambda_function.checker.function_name
}

output "table_name" {
  value = aws_dynamodb_table.history.name
}

output "status_bucket" {
  value = aws_s3_bucket.status.bucket
}
