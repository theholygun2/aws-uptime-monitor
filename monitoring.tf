# ---------------------------------------------------------------------------
# Heartbeat alarm: the monitor watches itself.
# The Lambda publishes Heartbeat = 1 on every run. If 2 of the last 3 minutes
# have no heartbeat (or missing data), the monitor is considered dead.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "heartbeat" {
  alarm_name          = "${local.name}-heartbeat-missing"
  alarm_description   = "The monitor stopped running: no heartbeat in 2 of the last 3 minutes"
  namespace           = local.namespace
  metric_name         = "Heartbeat"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------------------
# High latency alarm per target: average response time above the threshold
# for 3 of the last 5 minutes. Missing data is ignored here, because a target
# that is completely down already triggers its own down alarm.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "latency" {
  for_each = local.targets

  alarm_name          = "${local.name}-latency-${each.key}"
  alarm_description   = "${each.key} average response time above ${var.latency_threshold_ms} ms for 3 of the last 5 minutes"
  namespace           = local.namespace
  metric_name         = "ResponseTimeMs"
  dimensions          = { Target = each.key }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = var.latency_threshold_ms
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}
