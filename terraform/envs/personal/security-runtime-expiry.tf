# Stop control services when their explicit registration/quota expires; never extend approvals.
locals {
  security_runtime_stops = merge(
    local.build_consumer_enabled ? { "build-consumer" = { service_name = aws_ecs_service.build_consumer[0].name, expires_at = jsondecode(var.security_effect_budget_json).expires_at } } : {},
    { for name, item in var.security_observers : "security-${name}" => { service_name = aws_ecs_service.security_observer[name].name, expires_at = jsondecode(item.registration_json).expires_at } }
  )
}
resource "aws_scheduler_schedule_group" "security_runtime" {
  count = length(local.security_runtime_stops) > 0 ? 1 : 0
  name  = "${var.name_prefix}-security-runtime"
}
resource "aws_iam_role" "security_runtime_stop" {
  count              = length(local.security_runtime_stops) > 0 ? 1 : 0
  name               = "${var.name_prefix}-security-runtime-stop"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "scheduler.amazonaws.com" }, Action = "sts:AssumeRole", Condition = { StringEquals = { "aws:SourceAccount" = var.aws_account_id }, ArnEquals = { "aws:SourceArn" = aws_scheduler_schedule_group.security_runtime[0].arn } } }] })
}
resource "aws_iam_role_policy" "security_runtime_stop" {
  count  = length(local.security_runtime_stops) > 0 ? 1 : 0
  role   = aws_iam_role.security_runtime_stop[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["ecs:UpdateService"], Resource = [for item in values(local.security_runtime_stops) : "arn:aws:ecs:${var.region}:${var.aws_account_id}:service/${var.name_prefix}-outbox/${item.service_name}"] }] })
}
resource "aws_scheduler_schedule" "security_runtime_stop" {
  for_each                     = local.security_runtime_stops
  name                         = "${var.name_prefix}-stop-${each.key}"
  group_name                   = aws_scheduler_schedule_group.security_runtime[0].name
  schedule_expression          = "at(${formatdate("YYYY-MM-DD'T'hh:mm:ss", each.value.expires_at)})"
  schedule_expression_timezone = "UTC"
  action_after_completion      = "DELETE"
  flexible_time_window { mode = "OFF" }
  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ecs:updateService"
    role_arn = aws_iam_role.security_runtime_stop[0].arn
    input    = jsonencode({ Cluster = aws_ecs_cluster.outbox[0].arn, Service = each.value.service_name, DesiredCount = 0 })
    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 3
    }
  }
  depends_on = [aws_iam_role_policy.security_runtime_stop]
}
output "security_runtime_expiry" {
  value = { for name, item in local.security_runtime_stops : name => { service_name = item.service_name, expires_at = item.expires_at, schedule_arn = aws_scheduler_schedule.security_runtime_stop[name].arn } }
}

variable "trusted_controller_expiry" {
  type    = object({ instance_id = string, expires_at = string })
  default = null
  validation {
    condition = var.trusted_controller_expiry == null || try(
      var.hosted_build_consumer != null &&
      can(regex("^i-[a-f0-9]{17}$", var.trusted_controller_expiry.instance_id)) &&
      var.trusted_controller_expiry.expires_at == jsondecode(var.security_effect_budget_json).expires_at, false
    )
    error_message = "Stop only an explicitly registered controller at the original approved quota expiry."
  }
}
data "aws_instance" "controller_expiry" {
  count       = var.trusted_controller_expiry != null ? 1 : 0
  instance_id = var.trusted_controller_expiry.instance_id
}
resource "aws_iam_role_policy" "security_controller_stop" {
  count = var.trusted_controller_expiry != null ? 1 : 0
  role  = aws_iam_role.security_runtime_stop[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Allow", Action = ["ec2:StopInstances"], Resource = "arn:aws:ec2:${var.region}:${var.aws_account_id}:instance/${var.trusted_controller_expiry.instance_id}",
    Condition = { StringEquals = { "ec2:ResourceTag/sky:Purpose" = "trusted-controller", "ec2:ResourceTag/sky:NoWorkloadExecution" = "true" } }
  }] })
  lifecycle {
    precondition {
      condition     = try(data.aws_instance.controller_expiry[0].tags["sky:Purpose"] == "trusted-controller" && data.aws_instance.controller_expiry[0].tags["sky:NoWorkloadExecution"] == "true", false)
      error_message = "Only the registered trusted controller, never a workload VM, may be stopped."
    }
  }
}
resource "aws_scheduler_schedule" "security_controller_stop" {
  count                        = var.trusted_controller_expiry != null ? 1 : 0
  name                         = "${var.name_prefix}-stop-trusted-controller"
  group_name                   = aws_scheduler_schedule_group.security_runtime[0].name
  schedule_expression          = "at(${formatdate("YYYY-MM-DD'T'hh:mm:ss", var.trusted_controller_expiry.expires_at)})"
  schedule_expression_timezone = "UTC"
  action_after_completion      = "DELETE"
  flexible_time_window { mode = "OFF" }
  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.security_runtime_stop[0].arn
    input    = jsonencode({ InstanceIds = [var.trusted_controller_expiry.instance_id] })
    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 3
    }
  }
  depends_on = [aws_iam_role_policy.security_controller_stop]
}
