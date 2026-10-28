mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
}

variables {
  enable_shared_workload_pool   = false
  enable_build_worker_preflight = false
  build_worker_image            = null
  build_worker_builder_sha      = null
  build_worker_platform_sha     = null
  enable_build_worker_role      = false
  enable_builder_role           = false
  builder_oidc_subject          = null
  enable_public_api             = false
  public_api_image              = null
  api_memberships               = []
  enable_api_role               = false
  api_operator_principal_arn    = null
  aws_account_id                = "123456789012"
  enable_ssm_bridge             = false
  enable_outbox_service         = false
  outbox_service_image          = null
}

run "pool_is_opt_in" {
  command = plan
  assert {
    condition     = length(module.workload_pool) == 0 && output.shared_workload_pool_registration == null && length(aws_vpc_security_group_egress_rule.bridge_workload_database) == 0
    error_message = "Personal workload resources must remain opt-in."
  }
}

run "pool_requires_operator_bridge" {
  command = plan
  variables {
    enable_shared_workload_pool = true
  }
  expect_failures = [var.enable_shared_workload_pool]
}

run "reject_excessive_reservations" {
  command = plan
  variables {
    shared_workload_connection_budget = 31
  }
  expect_failures = [var.shared_workload_connection_budget]
}

run "bounded_separate_registration" {
  command = apply
  variables {
    enable_shared_workload_pool = true
    enable_ssm_bridge           = true
    ssm_bridge_ami_id           = "ami-0123456789abcdef0"
  }
  assert {
    condition = (
      output.shared_workload_pool_registration.settings.pool.instance_id == "sky-personal-workload-pool" &&
      output.shared_workload_pool_registration.settings.pool.control_database == "sky_pool_personal" &&
      output.shared_workload_pool_registration.settings.pool.connection_budget == 30 &&
      output.shared_workload_pool_registration.settings.pool.control_database != output.migration_environment.SKY_DATABASE_NAME
    )
    error_message = "Workload registration must be distinct from control-plane state and bound its connection budget."
  }
  assert {
    condition = (
      toset(output.shared_workload_pool_registration.settings.allowed_client_groups) == toset([aws_security_group.bridge[0].id, output.shared_workload_runtime_security_group_id]) &&
      aws_vpc_security_group_egress_rule.bridge_workload_database[0].security_group_id == aws_security_group.bridge[0].id &&
      aws_vpc_security_group_egress_rule.bridge_workload_database[0].referenced_security_group_id == output.shared_workload_pool_registration.settings.database_security_group &&
      length(aws_ecs_service.public_api) == 0
    )
    error_message = "Pool access must use the operator bridge and workload runtime groups, never API state permissions."
  }
}

