mock_provider "aws" {
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:targetgroup/sky-api/0123456789abcdef" }
  }

  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/sky-api/0123456789abcdef", dns_name = "internal-sky.ap-northeast-2.elb.amazonaws.com" }
  }
  mock_resource "aws_cloudfront_distribution" {
    defaults = { domain_name = "personal.cloudfront.net" }
  }
  mock_resource "aws_cognito_user_pool" {
    defaults = { id = "ap-northeast-2_TestPool", endpoint = "cognito-idp.ap-northeast-2.amazonaws.com/ap-northeast-2_TestPool" }
  }

  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock-runtime" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { region = "ap-northeast-2" }
  }
}

variables {
  enable_build_worker_role   = false
  enable_builder_role        = false
  builder_oidc_subject       = null
  enable_public_api          = false
  public_api_image           = null
  api_memberships            = []
  enable_api_role            = false
  api_operator_principal_arn = null
  aws_account_id             = "123456789012"
  enable_ssm_bridge          = false
  enable_outbox_service      = false
  outbox_service_image       = null
}

run "private_foundation" {
  command = apply

  assert {
    condition     = alltrue([for subnet in aws_subnet.data : !subnet.map_public_ip_on_launch])
    error_message = "Data subnets must not assign public IPs."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.database_from_tasks.referenced_security_group_id == aws_security_group.tasks.id && aws_vpc_security_group_ingress_rule.database_from_tasks.from_port == 5432 && aws_vpc_security_group_ingress_rule.database_from_tasks.to_port == 5432 && aws_vpc_security_group_ingress_rule.database_from_tasks.cidr_ipv4 == null
    error_message = "State DB access must be scoped to the task security group on PostgreSQL only."
  }

  assert {
    condition     = output.runtime_environment.SKY_STATE_WORKSPACE == "personal" && output.runtime_environment.SKY_AWS_ACCOUNT_ID == var.aws_account_id
    error_message = "Runtime references must remain scoped to the personal workspace/account."
  }
  assert {
    condition     = output.outbox_environment.SKY_DATABASE_SECRET_ARN == aws_secretsmanager_secret.state_outbox.arn && output.runtime_environment.SKY_DATABASE_SECRET_ARN == aws_secretsmanager_secret.state_api.arn && aws_secretsmanager_secret.state_outbox.name == "${var.name_prefix}/state-outbox"
    error_message = "API and outbox runtime references must use their dedicated Secret resources."
  }
}

run "state_database_protection" {
  command = plan
  module {
    source = "../../modules/state-db"
  }
  variables {
    name_prefix       = "sky-personal"
    data_subnet_ids   = ["subnet-11111111", "subnet-22222222"]
    security_group_id = "sg-11111111"
    instance_class    = "db.t4g.micro"
    multi_az          = false
  }
  assert {
    condition     = !aws_db_instance.this.publicly_accessible && aws_db_instance.this.storage_encrypted && aws_db_instance.this.deletion_protection && aws_db_instance.this.manage_master_user_password && !aws_db_instance.this.skip_final_snapshot
    error_message = "State DB must be private/encrypted/protected and use an RDS-managed credential."
  }
  assert {
    condition     = anytrue([for parameter in aws_db_parameter_group.this.parameter : parameter.name == "rds.force_ssl" && parameter.value == "1"])
    error_message = "State DB must reject non-TLS connections."
  }
}
run "bridge_has_no_database_credentials" {
  command = plan
  variables {
    enable_ssm_bridge = true
    ssm_bridge_ami_id = "ami-0123456789abcdef0"
  }
  assert {
    condition     = aws_instance.ssm_bridge[0].metadata_options[0].http_tokens == "required" && aws_instance.ssm_bridge[0].root_block_device[0].encrypted
    error_message = "Management instance must require IMDSv2 and encrypt its root volume."
  }
  assert {
    condition     = alltrue([for statement in jsondecode(aws_iam_role_policy.bridge[0].policy).Statement : alltrue([for action in statement.Action : startswith(action, "ssm:") || startswith(action, "ssmmessages:")])])
    error_message = "Bridge credentials must not grant database/secret/build access."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.database_from_bridge[0].from_port == 5432 && aws_vpc_security_group_ingress_rule.database_from_bridge[0].to_port == 5432
    error_message = "Bridge network access must be limited to PostgreSQL."
  }
}

run "publisher_is_trusted_send_only_service" {
  command = apply
  variables {
    enable_ssm_bridge     = true
    ssm_bridge_ami_id     = "ami-0123456789abcdef0"
    enable_outbox_service = true
    outbox_service_image  = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
  assert {
    condition     = toset(flatten([for statement in jsondecode(aws_iam_role_policy.outbox_task[0].policy).Statement : statement.Action])) == toset(["secretsmanager:GetSecretValue", "sqs:SendMessage"]) && jsondecode(aws_iam_role_policy.outbox_task[0].policy).Statement[0].Resource == aws_secretsmanager_secret.state_outbox.arn && jsondecode(aws_iam_role_policy.outbox_task[0].policy).Statement[1].Resource == module.queue.queue_arn
    error_message = "Publisher credentials must only read their own Secret and send to the configured queue."
  }
  assert {
    condition     = jsondecode(aws_iam_role.outbox_task[0].assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == var.aws_account_id && jsondecode(aws_iam_role.outbox_task[0].assume_role_policy).Statement[0].Condition.ArnLike["aws:SourceArn"] == "arn:aws:ecs:${var.region}:${var.aws_account_id}:*"
    error_message = "Task role trust must be scoped to the configured AWS account/region."
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.outbox[0].container_definitions)[0].readonlyRootFilesystem && jsondecode(aws_ecs_task_definition.outbox[0].container_definitions)[0].user == "65534:65534" && length(try(jsondecode(aws_ecs_task_definition.outbox[0].container_definitions)[0].mountPoints, [])) == 0 && length(try(jsondecode(aws_ecs_task_definition.outbox[0].container_definitions)[0].portMappings, [])) == 0
    error_message = "Publisher must run nonroot, readonly, without sockets, mounted workspaces or public listeners."
  }
  assert {
    condition     = join(" ", jsondecode(aws_ecs_task_definition.outbox[0].container_definitions)[0].command) == "worker --mode outbox --interval 15" && aws_ecs_service.outbox[0].desired_count == 1 && !aws_ecs_service.outbox[0].enable_execute_command
    error_message = "The service may only start a single outbox publisher, not a deployment consumer or remote shell."
  }
  assert {
    condition     = aws_subnet.publisher[0].cidr_block != aws_subnet.bridge[0].cidr_block && aws_vpc_security_group_ingress_rule.database_from_publisher[0].referenced_security_group_id == aws_security_group.publisher[0].id && aws_vpc_security_group_ingress_rule.database_from_publisher[0].cidr_ipv4 == null
    error_message = "Publisher must use its own subnet and security-group-only PostgreSQL access."
  }
}

run "publisher_rejects_mutable_image_tag" {
  command = plan
  variables {
    enable_ssm_bridge     = true
    ssm_bridge_ami_id     = "ami-0123456789abcdef0"
    enable_outbox_service = true
    outbox_service_image  = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform:latest"
  }
  expect_failures = [var.outbox_service_image]
}

run "api_is_disabled_by_default" {
  command = plan
  assert {
    condition     = length(aws_iam_role.api_task) == 0 && output.api_task_role_arn == null
    error_message = "API credentials must remain opt-in."
  }
}

run "api_has_no_deployment_or_publisher_access" {
  command = apply
  variables {
    enable_api_role = true
  }
  assert {
    condition     = toset(flatten([for s in jsondecode(aws_iam_role_policy.api_task[0].policy).Statement : s.Action])) == toset(["secretsmanager:GetSecretValue", "s3:GetObject", "s3:PutObject"]) && jsondecode(aws_iam_role_policy.api_task[0].policy).Statement[0].Resource == aws_secretsmanager_secret.state_api.arn
    error_message = "API must only read its own Secret and read/write source objects."
  }
  assert {
    condition     = alltrue([for s in slice(jsondecode(aws_iam_role_policy.api_task[0].policy).Statement, 1, 3) : s.Resource == "${module.artifacts.bucket_arn}/sources/personal/*" && s.Condition.StringEquals["s3:ResourceAccount"] == var.aws_account_id]) && jsondecode(aws_iam_role_policy.api_task[0].policy).Statement[2].Condition.StringEquals["s3:x-amz-server-side-encryption"] == "AES256" && !contains(keys(jsondecode(aws_iam_role_policy.api_task[0].policy).Statement[1].Condition.StringEquals), "s3:x-amz-server-side-encryption")
    error_message = "Source access must stay within the workspace/account, require AES256 on writes, and allow normal encrypted reads."
  }
  assert {
    condition     = length(jsondecode(aws_iam_role.api_task[0].assume_role_policy).Statement) == 1 && jsondecode(aws_iam_role.api_task[0].assume_role_policy).Statement[0].Principal.Service == "ecs-tasks.amazonaws.com" && jsondecode(aws_iam_role.api_task[0].assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == var.aws_account_id
    error_message = "Default API trust must be scoped ECS tasks only."
  }
}

run "api_local_operator_is_explicit" {
  command = apply
  variables {
    enable_api_role            = true
    api_operator_principal_arn = "arn:aws:iam::123456789012:user/local-operator"
  }
  assert {
    condition     = length(jsondecode(aws_iam_role.api_task[0].assume_role_policy).Statement) == 2 && jsondecode(aws_iam_role.api_task[0].assume_role_policy).Statement[1].Principal.AWS == var.api_operator_principal_arn && aws_iam_role.api_task[0].max_session_duration == 3600
    error_message = "Optional local trust must name only the exact configured operator."
  }
}

run "api_rejects_foreign_operator" {
  command = plan
  variables {
    enable_api_role            = true
    api_operator_principal_arn = "arn:aws:iam::999999999999:user/admin"
  }
  expect_failures = [var.api_operator_principal_arn]
}

run "api_rejects_wildcard_operator" {
  command = plan
  variables {
    enable_api_role            = true
    api_operator_principal_arn = "arn:aws:iam::123456789012:role/*"
  }
  expect_failures = [var.api_operator_principal_arn]
}

run "api_rejects_sts_session_principal" {
  command = plan
  variables {
    enable_api_role            = true
    api_operator_principal_arn = "arn:aws:sts::123456789012:assumed-role/operator/session"
  }
  expect_failures = [var.api_operator_principal_arn]
}

run "api_rejects_operator_when_disabled" {
  command = plan
  variables {
    enable_api_role            = false
    api_operator_principal_arn = "arn:aws:iam::123456789012:user/local-operator"
  }
  expect_failures = [var.api_operator_principal_arn]
}

run "public_api_is_opt_in" {
  command = plan
  assert {
    condition     = length(aws_lb.api) == 0 && length(aws_ecs_service.public_api) == 0 && output.public_api == null
    error_message = "The private foundation must not implicitly expose an API or create paid public hosting."
  }
}

run "public_api_has_private_origin_and_scoped_runtime" {
  command = apply
  variables {
    enable_public_api     = true
    enable_api_role       = true
    enable_ssm_bridge     = true
    ssm_bridge_ami_id     = "ami-0123456789abcdef0"
    enable_outbox_service = true
    outbox_service_image  = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    public_api_image      = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
  assert {
    condition     = aws_lb.api[0].internal && alltrue([for subnet in aws_subnet.api_edge : !subnet.map_public_ip_on_launch]) && aws_vpc_security_group_ingress_rule.api_from_cloudfront[0].referenced_security_group_id == data.aws_security_group.cloudfront_api[0].id && aws_vpc_security_group_ingress_rule.api_from_cloudfront[0].cidr_ipv4 == null && aws_vpc_security_group_ingress_rule.api_from_alb[0].referenced_security_group_id == aws_security_group.api_alb[0].id && aws_vpc_security_group_ingress_rule.api_from_alb[0].cidr_ipv4 == null
    error_message = "Only the managed CloudFront SG may reach the internal ALB, and only that ALB may reach the API."
  }
  assert {
    condition     = one(aws_cloudfront_distribution.api[0].default_cache_behavior).viewer_protocol_policy == "redirect-to-https" && one(aws_cloudfront_distribution.api[0].default_cache_behavior).cache_policy_id == data.aws_cloudfront_cache_policy.api_disabled[0].id && one(aws_cloudfront_origin_request_policy.api[0].headers_config).header_behavior == "allExcept" && one(one(aws_cloudfront_origin_request_policy.api[0].headers_config).headers).items == toset(["Host"])
    error_message = "HTTPS entry must disable caching and forward authorization/origin headers."
  }
  assert {
    condition     = aws_ecs_task_definition.public_api[0].task_role_arn == aws_iam_role.api_task[0].arn && jsondecode(aws_ecs_task_definition.public_api[0].container_definitions)[0].user == "65534:65534" && jsondecode(aws_ecs_task_definition.public_api[0].container_definitions)[0].readonlyRootFilesystem && length(jsondecode(aws_ecs_task_definition.public_api[0].container_definitions)[0].mountPoints) == 1 && jsondecode(aws_ecs_task_definition.public_api[0].container_definitions)[0].mountPoints[0].sourceVolume == "api-scratch" && jsondecode(aws_ecs_task_definition.public_api[0].container_definitions)[0].dependsOn[0].condition == "SUCCESS" && !jsondecode(aws_ecs_task_definition.public_api[0].container_definitions)[1].essential && one(aws_ecs_task_definition.public_api[0].volume).host_path == null && aws_ecs_service.public_api[0].desired_count == 1 && !aws_ecs_service.public_api[0].enable_execute_command
    error_message = "API must remain a nonroot, readonly, socket-free trusted task with its restricted role."
  }
  assert {
    condition     = local.public_api_environment.SKY_DATABASE_SECRET_ARN == aws_secretsmanager_secret.state_api.arn && local.public_api_environment.SKY_DEPLOYMENT_CONSUMER_ENABLED == "false" && length(jsondecode(local.public_api_environment.SKY_MEMBERSHIPS_JSON).members) == 0 && !contains(keys(local.public_api_environment), "OPENAI_API_KEY")
    error_message = "Runtime must not inherit administrator credentials, user grants, AI keys or deployment consumer activation."
  }
  assert {
    condition     = !aws_cognito_user_pool_client.api[0].generate_secret && aws_cognito_user_pool_client.api[0].allowed_oauth_flows == toset(["code"]) && aws_cognito_user_pool_client.api[0].callback_urls == toset(["https://${aws_cloudfront_distribution.api[0].domain_name}/auth/callback"]) && one(aws_cognito_user_pool.api[0].admin_create_user_config).allow_admin_create_user_only
    error_message = "Use public-client authorization code flow, exact callbacks, and explicit administrator-created users."
  }
}

run "public_api_rejects_mutable_image" {
  command = plan
  variables {
    enable_public_api     = true
    enable_api_role       = true
    enable_ssm_bridge     = true
    ssm_bridge_ami_id     = "ami-0123456789abcdef0"
    enable_outbox_service = true
    outbox_service_image  = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    public_api_image      = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform:latest"
  }
  expect_failures = [var.public_api_image]
}

run "public_api_requires_restricted_foundation" {
  command = plan
  variables {
    enable_public_api = true
    public_api_image  = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
  expect_failures = [var.enable_public_api]
}

run "memberships_reject_duplicates" {
  command = plan
  variables {
    enable_public_api     = true
    enable_api_role       = true
    enable_ssm_bridge     = true
    ssm_bridge_ami_id     = "ami-0123456789abcdef0"
    enable_outbox_service = true
    outbox_service_image  = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    public_api_image      = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/sky-platform@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    api_memberships = [
      { subject = "11111111-1111-4111-8111-111111111111", user_id = "alice", role = "deployer" },
      { subject = "11111111-1111-4111-8111-111111111111", user_id = "bob", role = "admin" }
    ]
  }
  expect_failures = [var.api_memberships]
}
