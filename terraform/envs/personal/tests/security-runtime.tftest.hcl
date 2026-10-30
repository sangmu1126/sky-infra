mock_provider "aws" {}

variables {
  api_operator_principal_arn    = null
  api_memberships               = []
  public_api_image              = null
  outbox_service_image          = null
  builder_oidc_subject          = null
  build_worker_image            = null
  build_worker_builder_sha      = null
  build_worker_platform_sha     = null
  security_effect_budget_json   = null
  aws_account_id                = "123456789012"
  enable_shared_workload_pool   = false
  enable_build_worker_preflight = false
  enable_build_worker_role      = false
  enable_public_api             = false
  enable_api_role               = false
  enable_ssm_bridge             = false
  enable_outbox_service         = false
  enable_builder_role           = false
}

run "no_implicit_policy_or_price" {
  command = plan
  assert {
    condition     = length(local.security_runtime_environment) == 0
    error_message = "An absent operator policy must not invent a budget or enable effects."
  }
}

run "explicit_expiring_policy_is_required_unchanged" {
  command = plan
  variables {
    security_effect_budget_json = jsonencode({
      version = 2, expires_at = "2099-01-01T00:00:00Z", source = "synthetic test quota; not a provider price"
      limits  = { for scope in ["global", "organization", "user", "application"] : scope => { requests = 1, build_seconds = 3600 } }
      effects = { github_build = { requests = 1, build_seconds = 3600 } }
    })
  }
  assert {
    condition     = local.security_runtime_environment.SKY_REQUIRE_EFFECT_BUDGETS == "true" && local.security_runtime_environment.SKY_EFFECT_BUDGET_JSON == var.security_effect_budget_json
    error_message = "Pass the explicit policy without inventing limits or dropping enforcement."
  }
}

run "reject_credentials_or_unbounded_policy_fields" {
  command = plan
  variables {
    security_effect_budget_json = "{\"version\":2,\"source\":\"test\",\"expires_at\":\"2099-01-01T00:00:00Z\",\"limits\":{},\"effects\":{},\"OPENAI_API_KEY\":\"synthetic-not-a-real-key\"}"
  }
  expect_failures = [var.security_effect_budget_json]
}

run "hosted_upload_rejects_build_only_budget" {
  command = plan
  variables {
    enable_public_api     = true
    enable_api_role       = true
    enable_ssm_bridge     = true
    ssm_bridge_ami_id     = "ami-0123456789abcdef0"
    enable_outbox_service = true
    outbox_service_image  = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    public_api_image      = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    security_effect_budget_json = jsonencode({
      version = 2, expires_at = "2099-01-01T00:00:00Z", source = "synthetic test, not a price"
      limits  = { for scope in ["global", "organization", "user", "application"] : scope => { requests = 1 } }
      effects = { github_build = { requests = 1 } }
    })
  }
  expect_failures = [var.security_effect_budget_json]
}
