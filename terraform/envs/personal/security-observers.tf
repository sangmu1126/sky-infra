# Read-only, app-registered observations. Detector keys are execution-time Secrets.
variable "security_observer_image" {
  type    = string
  default = null
  validation {
    condition     = length(var.security_observers) == 0 || can(regex("^${var.aws_account_id}\\.dkr\\.ecr\\.${var.region}\\.amazonaws\\.com/sky-platform@sha256:[0-9a-f]{64}$", var.security_observer_image))
    error_message = "Observer requires a CI-verified personal hosted image pinned by digest."
  }
}
variable "security_observers" {
  type    = map(object({ registration_json = string, desired_count = number }))
  default = {}
  validation {
    condition = length(var.security_observers) <= 4 && alltrue([for name, item in var.security_observers : try(
      can(regex("^[a-z][a-z0-9-]{1,12}$", name)) && contains([0, 1], item.desired_count) &&
      var.enable_build_worker_preflight &&
      jsondecode(item.registration_json).version == 1 &&
      jsondecode(item.registration_json).aws.account_id == var.aws_account_id &&
      jsondecode(item.registration_json).aws.region == var.region &&
      jsondecode(item.registration_json).detector.organization_id == "personal" &&
      can(regex("^arn:aws:iam::${var.aws_account_id}:role/sky-[A-Za-z0-9-]+$", jsondecode(item.registration_json).aws.role_arn)) &&
    can(timeadd(jsondecode(item.registration_json).expires_at, "0s")), false)])
    error_message = "Only explicitly registered same-account app observers with a bounded expiry may be activated."
  }
}
data "aws_sqs_queue" "security_review" {
  count = length(var.security_observers) > 0 ? 1 : 0
  name  = "sky-security-build-review"
}
data "aws_s3_bucket" "security_audit" {
  count  = length(var.security_observers) > 0 ? 1 : 0
  bucket = "sky-security-audit-${var.aws_account_id}-${var.region}"
}
resource "aws_security_group" "security_observer" {
  count       = length(var.security_observers) > 0 ? 1 : 0
  name        = "${var.name_prefix}-security-observer"
  description = "Read-only security observers: no ingress, no database route permission"
  vpc_id      = aws_vpc.this.id
}
resource "aws_vpc_security_group_egress_rule" "security_observer_https" {
  count             = length(var.security_observers) > 0 ? 1 : 0
  security_group_id = aws_security_group.security_observer[0].id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}
resource "aws_cloudwatch_log_group" "security_observer" {
  for_each          = var.security_observers
  name              = "/sky/${var.name_prefix}/security-${each.key}"
  retention_in_days = 7
}
resource "aws_secretsmanager_secret" "observer_signer" {
  for_each                = var.security_observers
  name                    = "${var.name_prefix}/security-observer-${each.key}-signer"
  description             = "Ed25519 detector key; value inserted outside Terraform"
  recovery_window_in_days = 30
  tags                    = { app = "sky", "sky:purpose" = "detector-signing", "sky:application" = jsondecode(each.value.registration_json).detector.application_id }
  lifecycle { prevent_destroy = true }
}
resource "aws_iam_role" "security_observer" {
  for_each           = var.security_observers
  name               = "${var.name_prefix}-security-${each.key}-reader"
  assume_role_policy = local.ecs_task_trust
}
resource "aws_iam_role" "security_observer_audit" {
  for_each           = var.security_observers
  name               = "${var.name_prefix}-security-${each.key}-audit"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { AWS = aws_iam_role.security_observer[each.key].arn }, Action = "sts:AssumeRole" }] })
}
resource "aws_iam_role_policy" "security_observer_audit" {
  for_each = var.security_observers
  role     = aws_iam_role.security_observer_audit[each.key].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["s3:PutObject"], Resource = "${data.aws_s3_bucket.security_audit[0].arn}/audit/personal/${jsondecode(each.value.registration_json).detector.application_id}/*" },
    { Effect = "Deny", Action = ["s3:GetObject", "s3:GetObjectVersion", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:PutBucketPolicy", "s3:PutLifecycleConfiguration"], Resource = "*" }
  ] })
}
resource "aws_iam_role_policy" "security_observer" {
  for_each = var.security_observers
  role     = aws_iam_role.security_observer[each.key].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["cloudtrail:LookupEvents"], Resource = "*", Condition = { StringEquals = { "aws:RequestedRegion" = var.region } } },
    { Effect = "Allow", Action = ["sts:AssumeRole"], Resource = aws_iam_role.security_observer_audit[each.key].arn },
    { Effect = "Allow", Action = ["sqs:GetQueueAttributes", "sqs:ListQueueTags", "sqs:SendMessage"], Resource = data.aws_sqs_queue.security_review[0].arn },
    { Effect = "Deny", Action = ["secretsmanager:GetSecretValue", "ssm:GetParameter", "ssm:GetParameters", "kms:Decrypt"], Resource = "*" }
  ] })
}
resource "aws_iam_role" "security_observer_execution" {
  for_each           = var.security_observers
  name               = "${var.name_prefix}-security-${each.key}-execution"
  assume_role_policy = local.ecs_task_trust
}
resource "aws_iam_role_policy" "security_observer_execution" {
  for_each = var.security_observers
  role     = aws_iam_role.security_observer_execution[each.key].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
    { Effect = "Allow", Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"], Resource = data.aws_ecr_repository.build_worker_runtime[0].arn },
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.security_observer[each.key].arn}:*" },
    { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = aws_secretsmanager_secret.observer_signer[each.key].arn }
  ] })
}
locals {
  security_observer_registration = { for name, item in var.security_observers : name => merge(jsondecode(item.registration_json), {
    audit            = { bucket = data.aws_s3_bucket.security_audit[0].id, role_arn = aws_iam_role.security_observer_audit[name].arn },
    review_queue_url = data.aws_sqs_queue.security_review[0].url
  }) }
}
resource "aws_ecs_task_definition" "security_observer" {
  for_each                 = var.security_observers
  family                   = "${var.name_prefix}-security-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.security_observer_execution[each.key].arn
  task_role_arn            = aws_iam_role.security_observer[each.key].arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name             = "observer", image = var.security_observer_image, essential = true, user = "65534:65534", readonlyRootFilesystem = true
    entryPoint       = ["python", "-c"], command = ["from interfaces.security_collector import hosted_main; hosted_main()"]
    environment      = [{ name = "SKY_SECURITY_REGISTRATION_JSON", value = jsonencode(local.security_observer_registration[each.key]) }, { name = "SKY_SECURITY_COLLECTOR_TASK_ROLE_ARN", value = aws_iam_role.security_observer[each.key].arn }]
    secrets          = [{ name = "SKY_SECURITY_SIGNING_PRIVATE_KEY", valueFrom = aws_secretsmanager_secret.observer_signer[each.key].arn }]
    mountPoints      = [], portMappings = [], systemControls = [], volumesFrom = []
    linuxParameters  = { capabilities = { add = [], drop = ["ALL"] } }
    healthCheck      = { command = ["CMD", "python", "-c", "pass"], interval = 30, timeout = 5, retries = 1 }
    stopTimeout      = 60
    logConfiguration = { logDriver = "awslogs", options = { awslogs-group = aws_cloudwatch_log_group.security_observer[each.key].name, awslogs-region = var.region, awslogs-stream-prefix = each.key } }
  }])
}
resource "aws_ecs_service" "security_observer" {
  for_each                           = var.security_observers
  name                               = "${var.name_prefix}-security-${each.key}"
  cluster                            = aws_ecs_cluster.outbox[0].id
  task_definition                    = aws_ecs_task_definition.security_observer[each.key].arn
  desired_count                      = each.value.desired_count
  launch_type                        = "FARGATE"
  platform_version                   = "1.4.0"
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  enable_execute_command             = false
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  network_configuration {
    subnets          = [aws_subnet.build_worker[0].id]
    security_groups  = [aws_security_group.security_observer[0].id]
    assign_public_ip = true
  }
  depends_on = [aws_iam_role_policy.security_observer, aws_iam_role_policy.security_observer_execution, aws_iam_role_policy.security_observer_audit, aws_vpc_security_group_egress_rule.security_observer_https]
}
output "security_observers" {
  value = { for name, item in var.security_observers : name => { service_name = aws_ecs_service.security_observer[name].name, task_definition_arn = aws_ecs_task_definition.security_observer[name].arn, signer_secret_arn = aws_secretsmanager_secret.observer_signer[name].arn, reader_role_arn = aws_iam_role.security_observer[name].arn, audit_role_arn = aws_iam_role.security_observer_audit[name].arn, registration = local.security_observer_registration[name], desired_count = item.desired_count } }
}

locals {
  active_security_observers = { for name, item in var.security_observers : name => item if item.desired_count == 1 }
}
resource "aws_cloudwatch_log_metric_filter" "security_observer_incomplete" {
  for_each       = local.active_security_observers
  name           = "${var.name_prefix}-${each.key}-collection-incomplete"
  log_group_name = aws_cloudwatch_log_group.security_observer[each.key].name
  pattern        = "{ ($.status = \"collection_incomplete\") || ($.collection_complete = false) }"
  metric_transformation {
    name          = "${var.name_prefix}-ObserverIncomplete-${each.key}"
    namespace     = "Sky/Security"
    value         = "1"
    default_value = 0
  }
}
resource "aws_cloudwatch_metric_alarm" "security_observer_incomplete" {
  for_each            = local.active_security_observers
  alarm_name          = "${var.name_prefix}-${each.key}-collection-incomplete"
  alarm_description   = "Collection failed or was partial; never interpret missing evidence as security clearance. No automatic hold release."
  namespace           = "Sky/Security"
  metric_name         = "${var.name_prefix}-ObserverIncomplete-${each.key}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = 1
  period              = 60
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"
}
resource "aws_cloudwatch_log_metric_filter" "security_observer_heartbeat" {
  for_each       = local.active_security_observers
  name           = "${var.name_prefix}-${each.key}-collection-heartbeat"
  log_group_name = aws_cloudwatch_log_group.security_observer[each.key].name
  pattern        = "{ $.status = \"review_recorded\" }"
  metric_transformation {
    name          = "${var.name_prefix}-ObserverHeartbeat-${each.key}"
    namespace     = "Sky/Security"
    value         = "1"
    default_value = 0
  }
}
resource "aws_cloudwatch_metric_alarm" "security_observer_stale" {
  for_each            = local.active_security_observers
  alarm_name          = "${var.name_prefix}-${each.key}-collector-stale"
  alarm_description   = "Three missing heartbeat periods out of five; observation unavailable, not a compromise assertion or automatic release. Expected after registration expiry."
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  treat_missing_data  = "breaching"
  # Explicit zeros avoid re-evaluating old healthy points when logs stop.
  # M-of-N tolerates the newest delayed ingestion periods without declaring
  # collection healthy merely because an older heartbeat still exists.
  metric_query {
    id          = "heartbeat"
    return_data = false
    metric {
      namespace   = "Sky/Security"
      metric_name = "${var.name_prefix}-ObserverHeartbeat-${each.key}"
      period      = 60
      stat        = "Sum"
    }
  }
  metric_query {
    id          = "available"
    expression  = "FILL(heartbeat, 0)"
    label       = "Successful collection heartbeat (missing = 0)"
    return_data = true
  }
}
