mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock-runtime" }
  }
}
variables {
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
run "worker_runtime_is_opt_in" {
  command = plan
  assert {
    condition     = output.build_worker_preflight == null && length(aws_ecs_task_definition.build_worker_preflight) == 0 && length(aws_subnet.build_worker) == 0
    error_message = "Worker runtime must remain opt-in and never activate a queue consumer."
  }
}
run "worker_rejects_unpinned_image" {
  command = plan
  variables {
    enable_ssm_bridge             = true
    ssm_bridge_ami_id             = "ami-0123456789abcdef0"
    enable_outbox_service         = true
    outbox_service_image          = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    enable_build_worker_role      = true
    enable_build_worker_preflight = true
    build_worker_image            = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform:latest"
    build_worker_builder_sha      = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    build_worker_platform_sha     = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
  expect_failures = [var.build_worker_image]
}
run "worker_preflight_has_separate_runtime_and_no_consumer" {
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
  }
  assert {
    condition     = aws_ecs_task_definition.build_worker_preflight[0].task_role_arn == aws_iam_role.build_worker[0].arn && aws_ecs_task_definition.build_worker_preflight[0].execution_role_arn == aws_iam_role.build_worker_execution[0].arn && jsondecode(aws_ecs_task_definition.build_worker_preflight[0].container_definitions)[0].readonlyRootFilesystem && jsondecode(aws_ecs_task_definition.build_worker_preflight[0].container_definitions)[0].user == "65534:65534" && length(jsondecode(aws_ecs_task_definition.build_worker_preflight[0].container_definitions)[0].mountPoints) == 0 && length(jsondecode(aws_ecs_task_definition.build_worker_preflight[0].container_definitions)[0].portMappings) == 0
    error_message = "Trusted preflight must run nonroot/read-only with its own execution and worker roles, no mounts or listeners."
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.build_worker_preflight[0].container_definitions)[0].entryPoint == ["python", "-c"] && jsondecode(aws_ecs_task_definition.build_worker_preflight[0].container_definitions)[0].command == [file("${path.module}/../../../scripts/build_worker_preflight.py")]
    error_message = "Only the reviewed fixed preflight may run; no build consumer command."
  }
  assert {
    condition     = aws_subnet.build_worker[0].cidr_block == "10.42.3.0/24" && !aws_subnet.build_worker[0].map_public_ip_on_launch && aws_vpc_security_group_ingress_rule.database_from_build_worker[0].referenced_security_group_id == aws_security_group.build_worker[0].id && aws_vpc_security_group_egress_rule.build_worker_database[0].referenced_security_group_id == aws_security_group.database.id && length(aws_security_group.build_worker[0].ingress) == 0
    error_message = "Worker runtime must have no ingress and its own SG-scoped private database access."
  }
  assert {
    condition     = toset(flatten([for s in jsondecode(aws_iam_role_policy.build_worker_execution[0].policy).Statement : s.Action])) == toset(["ecr:GetAuthorizationToken", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability", "logs:CreateLogStream", "logs:PutLogEvents"])
    error_message = "Execution identity must only pull images and write its logs, not read application secrets or consume jobs."
  }
}
