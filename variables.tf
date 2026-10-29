variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-southeast-1"
}

variable "alert_email" {
  description = "Email address that receives down alerts"
  type        = string
}

variable "targets" {
  description = "Services to monitor. expected_status is the HTTP code that counts as healthy."
  type = list(object({
    name            = string
    url             = string
    expected_status = optional(number, 200)
  }))

  default = [
    {
      name = "portfolio"
      url  = "https://example.com"
    },
  ]
}

variable "retention_days" {
  description = "How many days of check history to keep in DynamoDB (TTL)"
  type        = number
  default     = 7
}

variable "availability_window_hours" {
  description = "Window used to calculate availability and latency on the status page"
  type        = number
  default     = 24
}

variable "latency_threshold_ms" {
  description = "Average response time (ms) above which the high-latency alarm fires"
  type        = number
  default     = 2000
}
