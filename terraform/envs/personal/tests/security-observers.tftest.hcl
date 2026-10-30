mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::123456789012:role/mock-runtime" } }
  mock_data "aws_s3_bucket" { defaults = { id = "sky-security-audit-123456789012-ap-northeast-2", arn = "arn:aws:s3:::sky-security-audit-123456789012-ap-northeast-2" } }
  mock_data "aws_sqs_queue" { defaults = { arn = "arn:aws:sqs:ap-northeast-2:123456789012:sky-security-build-review", url = "https://sqs.ap-northeast-2.amazonaws.com/123456789012/sky-security-build-review" } }
}
variables {
  trusted_controller_expiry         = null
  hosted_build_consumer             = null
  security_observers                = {}
  enable_security_acceptance_canary = false
  security_canary_read_enabled      = false
  enable_shared_workload_pool       = false
  aws_account_id                    = "123456789012"
  enable_public_api                 = false
  public_api_image                  = null
  api_memberships                   = []
  enable_api_role                   = false
  api_operator_principal_arn        = null
  enable_ssm_bridge                 = false
  enable_outbox_service             = false
  outbox_service_image              = null
  enable_builder_role               = false
  builder_oidc_subject              = null
  enable_build_worker_role          = false
  enable_build_worker_preflight     = false
  build_worker_image                = null
  build_worker_builder_sha          = null
  build_worker_platform_sha         = null
}

run "no_implicit_observer_canary_or_timer" {
  command = plan
  assert {
    condition     = length(aws_ecs_service.security_observer) == 0 && length(aws_iam_role.security_canary) == 0 && length(aws_scheduler_schedule.security_runtime_stop) == 0
    error_message = "No observation, canary permission or stop schedule without explicit opt-in."
  }
}
run "canary_denies_reads_until_explicit_acceptance_test" {
  command = apply
  variables {
    enable_ssm_bridge             = true
    ssm_bridge_ami_id             = "ami-0123456789abcdef0"
    enable_outbox_service         = true
    outbox_service_image          = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    enable_build_worker_role      = true
    enable_build_worker_preflight = true
    build_worker_image            = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    build_worker_builder_sha      = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    build_worker_platform_sha     = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    enable_security_acceptance_canary = true
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.security_canary[0].policy).Statement[0].Effect == "Deny" && jsondecode(aws_iam_role_policy.security_canary[0].policy).Statement[0].Resource == aws_secretsmanager_secret.security_canary[0].arn
    error_message = "A canary cannot obtain read permission by default or touch real user secrets."
  }
}

run "registered_observer_is_read_only_and_has_independent_audit_writer" {
  command = apply
  variables {

    enable_ssm_bridge             = true
    ssm_bridge_ami_id             = "ami-0123456789abcdef0"
    enable_outbox_service         = true
    outbox_service_image          = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    enable_build_worker_role      = true
    enable_build_worker_preflight = true
    build_worker_image            = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    build_worker_builder_sha      = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    build_worker_platform_sha     = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    security_observer_image = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    security_observers      = { probe = { desired_count = 1, registration_json = jsonencode({ version = 1, expires_at = "2099-01-01T00:00:00Z", aws = { account_id = "123456789012", region = "ap-northeast-2", role_arn = "arn:aws:iam::123456789012:role/sky-probe", role_id = "AROAAAAAAAAAAAAAAAAAA", forbidden_secrets = ["arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:sky-probe-AbCdEf"] }, detector = { detector_id = "probe", organization_id = "personal", application_id = "probe", public_key = "synthetic mock public key", reasons = ["credential_exposure"] }, scope = { job_id = "aaaaaaaaaaaaaaaa", source_digest = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", record_revision = 1 }, audit = {} }) } }
  }
  assert {
    condition     = alltrue([for s in jsondecode(aws_iam_role_policy.security_observer["probe"].policy).Statement : s.Effect != "Allow" || length(setintersection(toset(s.Action), toset(["secretsmanager:GetSecretValue", "ecs:UpdateService", "iam:PassRole", "s3:PutObject"]))) == 0]) && length([for s in jsondecode(aws_iam_role_policy.security_observer["probe"].policy).Statement : s if s.Effect == "Deny" && contains(s.Action, "secretsmanager:GetSecretValue")]) == 1
    error_message = "Observer cannot fetch application secrets, deploy, bypass role boundaries or write audit using its own credentials."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.security_observer_audit["probe"].policy).Statement[0].Resource == "arn:aws:s3:::sky-security-audit-123456789012-ap-northeast-2/audit/personal/probe/*"
    error_message = "Independent audit credentials may append to only the registered application."
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.security_observer["probe"].container_definitions)[0].readonlyRootFilesystem && jsondecode(aws_ecs_task_definition.security_observer["probe"].container_definitions)[0].user == "65534:65534" && length(jsondecode(aws_ecs_task_definition.security_observer["probe"].container_definitions)[0].mountPoints) == 0 && length(jsondecode(aws_ecs_task_definition.security_observer["probe"].container_definitions)[0].portMappings) == 0
    error_message = "Hosted collection must run rootless/read-only without source checkout, key files, listeners or Docker sockets."
  }
  assert {
    condition     = jsondecode(aws_scheduler_schedule.security_runtime_stop["security-probe"].target[0].input).DesiredCount == 0 && aws_scheduler_schedule.security_runtime_stop["security-probe"].schedule_expression == "at(2099-01-01T00:00:00)"
    error_message = "Registration expiry must schedule a stop without extending its approval."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.security_observer_stale["probe"].evaluation_periods == 5 && aws_cloudwatch_metric_alarm.security_observer_stale["probe"].datapoints_to_alarm == 3 && length([for query in aws_cloudwatch_metric_alarm.security_observer_stale["probe"].metric_query : query if query.return_data && query.expression == "FILL(heartbeat, 0)"]) == 1
    error_message = "Missing collection heartbeats must become zero with bounded ingestion-delay tolerance, rather than reusing old healthy points."
  }

}
