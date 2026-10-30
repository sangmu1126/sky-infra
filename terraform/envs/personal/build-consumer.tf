# Credentials and resources for a trusted, Docker-free consumer. No implicit activation.
variable "hosted_build_consumer" {
  type = object({
    app_id             = string
    installation_id    = string
    signing_trust_json = string
    desired_count      = number
  })
  default = null
  validation {
    condition = var.hosted_build_consumer == null || try(
      var.enable_build_worker_preflight && var.security_effect_budget_json != null &&
      contains([0, 1], var.hosted_build_consumer.desired_count) &&
      can(regex("^[0-9]{1,20}$", var.hosted_build_consumer.app_id)) &&
      can(regex("^[0-9]{1,20}$", var.hosted_build_consumer.installation_id)) &&
      jsondecode(var.hosted_build_consumer.signing_trust_json).version == 1 &&
      jsondecode(var.hosted_build_consumer.signing_trust_json).key_arn == var.builder_signing_key_arn &&
      length(jsondecode(var.hosted_build_consumer.signing_trust_json).public_key_der_base64) > 0, false
    )
    error_message = "Explicit App IDs, exact public signing trust, expiring quota and existing worker preflight are required; stage at zero before inserting the Secret."
  }
}
locals { build_consumer_enabled = var.hosted_build_consumer != null }
data "aws_cloudformation_stack" "build_consumer_core" {
  count = local.build_consumer_enabled ? 1 : 0
  name  = "sky-core"
}
resource "aws_secretsmanager_secret" "github_app" {
  count                   = local.build_consumer_enabled ? 1 : 0
  name                    = "${var.name_prefix}/github-app-private-key"
  description             = "Builder App key; value inserted outside Terraform and never in state"
  recovery_window_in_days = 30
  tags                    = { app = "sky", "sky:purpose" = "builder-app-auth" }
  lifecycle { prevent_destroy = true }
}
resource "aws_iam_role" "build_consumer_execution" {
  count              = local.build_consumer_enabled ? 1 : 0
  name               = "${var.name_prefix}-build-consumer-execution"
  assume_role_policy = local.ecs_task_trust
}
resource "aws_iam_role_policy" "build_consumer_execution" {
  count = local.build_consumer_enabled ? 1 : 0
  role  = aws_iam_role.build_consumer_execution[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
    { Effect = "Allow", Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"], Resource = data.aws_ecr_repository.build_worker_runtime[0].arn },
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.build_worker[0].arn}:*" },
    { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = aws_secretsmanager_secret.github_app[0].arn }
  ] })
}
resource "aws_iam_role_policy" "build_consumer_deployment" {
  count = local.build_consumer_enabled ? 1 : 0
  role  = aws_iam_role.build_worker[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "ObserveRegisteredSigningKey", Effect = "Allow", Action = ["kms:DescribeKey", "kms:GetPublicKey"], Resource = var.builder_signing_key_arn },
    { Sid = "ReadOwnedCore", Effect = "Allow", Action = ["cloudformation:DescribeStacks"], Resource = data.aws_cloudformation_stack.build_consumer_core[0].id },
    { Sid = "CreateOwnedStatelessService", Effect = "Allow", Action = ["ecs:CreateExpressGatewayService"], Resource = "arn:aws:ecs:${var.region}:${var.aws_account_id}:service/default/sky-b-*",
    Condition = { StringEquals = { "aws:RequestTag/sky-managed" = "true", "aws:RequestTag/sky-organization" = "personal", "aws:RequestTag/sky-workspace" = "personal" }, Null = { "aws:RequestTag/sky-operation" = "false", "aws:RequestTag/sky-application" = "false", "aws:RequestTag/sky-attempt" = "false" } } },
    { Sid = "TagOnlyOnCreation", Effect = "Allow", Action = ["ecs:TagResource"], Resource = "arn:aws:ecs:${var.region}:${var.aws_account_id}:service/default/sky-b-*",
    Condition = { StringEquals = { "ecs:CreateAction" = "CreateExpressGatewayService", "aws:RequestTag/sky-managed" = "true", "aws:RequestTag/sky-organization" = "personal", "aws:RequestTag/sky-workspace" = "personal" } } },
    { Sid = "ObserveApprovedServices", Effect = "Allow", Action = ["ecs:DescribeExpressGatewayService", "ecs:ListTagsForResource"], Resource = "arn:aws:ecs:${var.region}:${var.aws_account_id}:service/default/sky-b-*" },
    { Sid = "ObserveExactDeploymentFamilies", Effect = "Allow", Action = ["ecs:DescribeServiceDeployments"], Resource = ["arn:aws:ecs:${var.region}:${var.aws_account_id}:service-deployment/default/sky-b-*/*", "arn:aws:ecs:${var.region}:${var.aws_account_id}:service/default/sky-b-*"] },
    { Sid = "ObserveTaskDefinitions", Effect = "Allow", Action = ["ecs:DescribeTaskDefinition"], Resource = "*" },
    # AWS requires these dependent actions; scope writes to generated app families.
    { Sid = "DefaultClusterOnly", Effect = "Allow", Action = ["ecs:CreateCluster"], Resource = "arn:aws:ecs:${var.region}:${var.aws_account_id}:cluster/default" },
    { Sid = "RegisterOnlyAppTaskFamilies", Effect = "Allow", Action = ["ecs:RegisterTaskDefinition"], Resource = "arn:aws:ecs:${var.region}:${var.aws_account_id}:task-definition/default-sky-b-*:*", Condition = { BoolIfExists = { "ecs:privileged" = "false" } } },
    { Sid = "TagTaskOnlyOnRegistration", Effect = "Allow", Action = ["ecs:TagResource"], Resource = "arn:aws:ecs:${var.region}:${var.aws_account_id}:task-definition/default-sky-b-*:*", Condition = { StringEquals = { "ecs:CreateAction" = "RegisterTaskDefinition" } } },
    { Sid = "PassCoreExecutionRoleToTasks", Effect = "Allow", Action = ["iam:PassRole"], Resource = data.aws_cloudformation_stack.build_consumer_core[0].outputs.ExecutionRoleArn, Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } } },
    { Sid = "PassOnlyCoreRolesToExpress", Effect = "Allow", Action = ["iam:PassRole"], Resource = [data.aws_cloudformation_stack.build_consumer_core[0].outputs.ExecutionRoleArn, data.aws_cloudformation_stack.build_consumer_core[0].outputs.InfrastructureRoleArn], Condition = { StringEquals = { "iam:PassedToService" = "ecs.amazonaws.com" } } }
  ] })
  lifecycle {
    precondition {
      condition     = can(regex("^arn:aws:iam::${var.aws_account_id}:role/sky-core-ExecutionRole-[A-Za-z0-9]+$", data.aws_cloudformation_stack.build_consumer_core[0].outputs.ExecutionRoleArn)) && can(regex("^arn:aws:iam::${var.aws_account_id}:role/sky-core-InfrastructureRole-[A-Za-z0-9]+$", data.aws_cloudformation_stack.build_consumer_core[0].outputs.InfrastructureRoleArn))
      error_message = "Only existing same-account sky-core execution and infrastructure roles may be passed."
    }
  }
}
resource "aws_ecs_task_definition" "build_consumer" {
  count                    = local.build_consumer_enabled ? 1 : 0
  family                   = "${var.name_prefix}-build-consumer"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.build_consumer_execution[0].arn
  task_role_arn            = aws_iam_role.build_worker[0].arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name    = "build-consumer", image = var.build_worker_image, essential = true, user = "65534:65534", readonlyRootFilesystem = true
    command = ["worker", "--mode", "build", "--deploy-built-image", "--interval", "5"]
    environment = [for name, value in merge(local.state_environment, local.security_runtime_environment, {
      SKY_DATABASE_SECRET_ARN    = aws_secretsmanager_secret.state_build[0].arn
      SKY_BUILDER_REPOSITORY     = "sangmu1126/sky-builder", SKY_BUILDER_REF = "main"
      SKY_BUILDER_SHA            = var.build_worker_builder_sha, SKY_BUILDER_PLATFORM_SHA = var.build_worker_platform_sha
      SKY_GITHUB_APP_ID          = var.hosted_build_consumer.app_id, SKY_GITHUB_INSTALLATION_ID = var.hosted_build_consumer.installation_id
      SKY_REQUIRE_SIGNED_BUILDS  = "true", SKY_BUILD_SIGNING_TRUST_JSON = var.hosted_build_consumer.signing_trust_json
      SKY_REQUIRE_EFFECT_BUDGETS = "true"
    }) : { name = name, value = value }]
    secrets          = [{ name = "SKY_GITHUB_APP_PRIVATE_KEY", valueFrom = aws_secretsmanager_secret.github_app[0].arn }]
    mountPoints      = [], portMappings = [], systemControls = [], volumesFrom = []
    linuxParameters  = { capabilities = { add = [], drop = ["ALL"] } }
    healthCheck      = { command = ["CMD", "python", "-c", "pass"], interval = 30, timeout = 5, retries = 1 }
    stopTimeout      = 120
    logConfiguration = { logDriver = "awslogs", options = { awslogs-group = aws_cloudwatch_log_group.build_worker[0].name, awslogs-region = var.region, awslogs-stream-prefix = "consumer" } }
  }])
}
resource "aws_ecs_service" "build_consumer" {
  count                              = local.build_consumer_enabled ? 1 : 0
  name                               = "${var.name_prefix}-build-consumer"
  cluster                            = aws_ecs_cluster.outbox[0].id
  task_definition                    = aws_ecs_task_definition.build_consumer[0].arn
  desired_count                      = var.hosted_build_consumer.desired_count
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
    security_groups  = [aws_security_group.build_worker[0].id]
    assign_public_ip = true
  }
  depends_on = [aws_iam_role_policy.build_consumer_execution, aws_iam_role_policy.build_consumer_deployment, aws_iam_role_policy.build_worker, aws_route_table_association.build_worker, aws_vpc_security_group_ingress_rule.database_from_build_worker]
}
output "build_consumer" {
  value = local.build_consumer_enabled ? {
    cluster_arn         = aws_ecs_cluster.outbox[0].arn, service_name = aws_ecs_service.build_consumer[0].name
    task_definition_arn = aws_ecs_task_definition.build_consumer[0].arn, app_secret_arn = aws_secretsmanager_secret.github_app[0].arn
    log_group           = aws_cloudwatch_log_group.build_worker[0].name, desired_count = var.hosted_build_consumer.desired_count
  } : null
}
