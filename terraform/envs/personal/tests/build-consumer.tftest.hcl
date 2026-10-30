mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_cloudformation_stack" {
    defaults = { id = "arn:aws:cloudformation:ap-northeast-2:123456789012:stack/sky-core/synthetic", outputs = { ExecutionRoleArn = "arn:aws:iam::123456789012:role/sky-core-ExecutionRole-Synthetic", InfrastructureRoleArn = "arn:aws:iam::123456789012:role/sky-core-InfrastructureRole-Synthetic" } }
  }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::123456789012:role/mock-runtime" } }
}
variables {
  enable_shared_workload_pool   = false
  aws_account_id                = "123456789012"
  enable_public_api             = false
  public_api_image              = null
  api_memberships               = []
  enable_api_role               = false
  api_operator_principal_arn    = null
  enable_ssm_bridge             = false
  enable_outbox_service         = false
  outbox_service_image          = null
  enable_builder_role           = false
  builder_oidc_subject          = null
  enable_build_worker_role      = false
  enable_build_worker_preflight = false
  build_worker_image            = null
  build_worker_builder_sha      = null
  build_worker_platform_sha     = null
}

run "consumer_and_secret_absent_without_opt_in" {
  command = plan
  assert {
    condition     = output.build_consumer == null && length(aws_ecs_service.build_consumer) == 0 && length(aws_secretsmanager_secret.github_app) == 0
    error_message = "No worker, secret or deployment permission may appear by default."
  }
}
run "staged_worker_preserves_credentials_and_runtime_boundaries" {
  command = apply
  variables {
    enable_ssm_bridge             = true
    ssm_bridge_ami_id             = "ami-0123456789abcdef0"
    enable_outbox_service         = true
    outbox_service_image          = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    enable_build_worker_role      = true
    enable_build_worker_preflight = true
    build_worker_image            = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    build_worker_builder_sha      = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    build_worker_platform_sha     = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    builder_signing_key_arn       = "arn:aws:kms:ap-northeast-2:123456789012:key/00000000-0000-4000-8000-000000000001"
    security_effect_budget_json   = jsonencode({ version = 2, expires_at = "2099-01-01T00:00:00Z", source = "synthetic mock policy", limits = {}, effects = {} })
    hosted_build_consumer = {
      app_id             = "12345", installation_id = "67890", desired_count = 0
      signing_trust_json = jsonencode({ version = 1, key_arn = "arn:aws:kms:ap-northeast-2:123456789012:key/00000000-0000-4000-8000-000000000001", public_key_der_base64 = "synthetic-mock-key" })
    }
  }
  assert {
    condition     = aws_ecs_service.build_consumer[0].desired_count == 0 && aws_ecs_task_definition.build_consumer[0].task_role_arn == aws_iam_role.build_worker[0].arn && aws_ecs_task_definition.build_consumer[0].execution_role_arn == aws_iam_role.build_consumer_execution[0].arn
    error_message = "Stage at zero with separate runtime/execution credentials."
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.build_consumer[0].container_definitions)[0].readonlyRootFilesystem && jsondecode(aws_ecs_task_definition.build_consumer[0].container_definitions)[0].user == "65534:65534" && length(jsondecode(aws_ecs_task_definition.build_consumer[0].container_definitions)[0].mountPoints) == 0 && length(jsondecode(aws_ecs_task_definition.build_consumer[0].container_definitions)[0].portMappings) == 0
    error_message = "The credential-bearing worker cannot have a Docker socket, listener or root runtime."
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.build_consumer[0].container_definitions)[0].secrets == [{ name = "SKY_GITHUB_APP_PRIVATE_KEY", valueFrom = aws_secretsmanager_secret.github_app[0].arn }] && !contains([for e in jsondecode(aws_ecs_task_definition.build_consumer[0].container_definitions)[0].environment : e.name], "SKY_GITHUB_APP_PRIVATE_KEY")
    error_message = "App key is a Secret reference, never a public environment value or Terraform-managed secret version."
  }
  assert {
    condition     = alltrue([for p in jsondecode(aws_iam_role_policy.build_consumer_deployment[0].policy).Statement : !contains(p.Action, "iam:CreateRole") && !contains(p.Action, "kms:Sign") && !contains(p.Action, "secretsmanager:GetSecretValue") && !contains(p.Action, "ec2:RunInstances")])
    error_message = "Worker must not execute guest code, sign its own results, create roles or read App keys by AWS API."
  }
  assert {
    condition     = [for p in jsondecode(aws_iam_role_policy.build_consumer_deployment[0].policy).Statement : p.Condition.StringEquals["aws:RequestTag/sky-workspace"] if p.Sid == "CreateOwnedStatelessService"] == ["personal"] && [for p in jsondecode(aws_iam_role_policy.build_consumer_deployment[0].policy).Statement : p.Condition.StringEquals["iam:PassedToService"] if p.Sid == "PassOnlyCoreRolesToExpress"] == ["ecs.amazonaws.com"]
    error_message = "Deployment grants must preserve ownership and exact service-bound role passing."
  }
}
run "consumer_rejects_missing_budget" {
  command = plan
  variables {
    enable_ssm_bridge             = true
    ssm_bridge_ami_id             = "ami-0123456789abcdef0"
    enable_outbox_service         = true
    outbox_service_image          = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    enable_build_worker_role      = true
    enable_build_worker_preflight = true
    build_worker_image            = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    build_worker_builder_sha      = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    build_worker_platform_sha     = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    builder_signing_key_arn       = "arn:aws:kms:ap-northeast-2:123456789012:key/00000000-0000-4000-8000-000000000001"
    hosted_build_consumer = {
      app_id             = "12345", installation_id = "67890", desired_count = 0
      signing_trust_json = jsonencode({ version = 1, key_arn = "arn:aws:kms:ap-northeast-2:123456789012:key/00000000-0000-4000-8000-000000000001", public_key_der_base64 = "synthetic-mock-key" })
    }

    security_effect_budget_json = null
  }
  expect_failures = [var.hosted_build_consumer]
}
