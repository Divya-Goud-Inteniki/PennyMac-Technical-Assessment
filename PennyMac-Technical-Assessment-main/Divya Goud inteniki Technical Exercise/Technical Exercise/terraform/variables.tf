variable "region" {
  description = "AWS Region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name prefix for resources"
  type        = string
  default     = "snapshot-cleaner"
}

variable "retention_days" {
  description = "Retention period in days. Snapshots older than this will be deleted."
  type        = number
  default     = 365
}

variable "schedule_expression" {
  description = "EventBridge schedule expression"
  type        = string
  default     = "rate(1 day)"
}

variable "dry_run" {
  description = "If true, Lambda only logs what it would delete"
  type        = bool
  default     = false
}
