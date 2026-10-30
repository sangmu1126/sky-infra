# App/job scoped temporary deployment credentials. No uploaded code runs here.
variable "enable_scoped_deployments" {
  type    = bool
  default = false
  validation {
    condition     = !var.enable_scoped_deployments || (var.hosted_build_consumer != null && var.security_effect_budget_json != null)
    error_message = "Scoped deployment needs an existing consumer and expiring operator budget."
  }
}
locals {
  legacy_consumer_deployment_permissions = jsondecode(local.build_consumer_enabled ? jsonencode([
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

  ]) : "[]")
  broker_deployment_permissions = jsondecode(local.build_consumer_enabled ? jsonencode([
    { Sid = "ReadOwnedCore", Effect = "Allow", Action = ["cloudformation:DescribeStacks"], Resource = data.aws_cloudformation_stack.build_consumer_core[0].id },
    { Sid = "CreateOwnedStatelessService", Effect = "Allow", Action = ["ecs:CreateExpressGatewayService"], Resource = "arn:aws:ecs:${var.region}:${var.aws_account_id}:service/default/sky-b-$${aws:PrincipalTag/sky:DeploymentToken}",
    Condition = { StringEquals = { "aws:RequestTag/sky-managed" = "true", "aws:RequestTag/sky-organization" = "$${aws:PrincipalTag/sky:OrganizationId}", "aws:RequestTag/sky-workspace" = "$${aws:PrincipalTag/sky:Workspace}", "aws:RequestTag/sky-application" = "$${aws:PrincipalTag/sky:ApplicationId}" }, Null = { "aws:RequestTag/sky-operation" = "false", "aws:RequestTag/sky-application" = "false", "aws:RequestTag/sky-attempt" = "false" } } },
    { Sid = "TagOnlyOnCreation", Effect = "Allow", Action = ["ecs:TagResource"], Resource = "arn:aws:ecs:${var.region}:${var.aws_account_id}:service/default/sky-b-$${aws:PrincipalTag/sky:DeploymentToken}",
    Condition = { StringEquals = { "ecs:CreateAction" = "CreateExpressGatewayService", "aws:RequestTag/sky-managed" = "true", "aws:RequestTag/sky-organization" = "$${aws:PrincipalTag/sky:OrganizationId}", "aws:RequestTag/sky-workspace" = "$${aws:PrincipalTag/sky:Workspace}", "aws:RequestTag/sky-application" = "$${aws:PrincipalTag/sky:ApplicationId}" } } },
    { Sid = "ObserveApprovedServices", Effect = "Allow", Action = ["ecs:DescribeExpressGatewayService", "ecs:DeleteExpressGatewayService", "ecs:ListTagsForResource"], Resource = "arn:aws:ecs:${var.region}:${var.aws_account_id}:service/default/sky-b-$${aws:PrincipalTag/sky:DeploymentToken}" },
    { Sid = "ObserveExactDeploymentFamilies", Effect = "Allow", Action = ["ecs:DescribeServiceDeployments"], Resource = ["arn:aws:ecs:${var.region}:${var.aws_account_id}:service-deployment/default/sky-b-$${aws:PrincipalTag/sky:DeploymentToken}/*", "arn:aws:ecs:${var.region}:${var.aws_account_id}:service/default/sky-b-$${aws:PrincipalTag/sky:DeploymentToken}"] },
    { Sid = "ObserveTaskDefinitions", Effect = "Allow", Action = ["ecs:DescribeTaskDefinition"], Resource = "*" },
    # AWS requires these dependent actions; scope writes to generated app families.
    { Sid = "DefaultClusterOnly", Effect = "Allow", Action = ["ecs:CreateCluster"], Resource = "arn:aws:ecs:${var.region}:${var.aws_account_id}:cluster/default" },
    { Sid = "RegisterOnlyAppTaskFamilies", Effect = "Allow", Action = ["ecs:RegisterTaskDefinition"], Resource = "arn:aws:ecs:${var.region}:${var.aws_account_id}:task-definition/default-sky-b-$${aws:PrincipalTag/sky:DeploymentToken}:*", Condition = { StringEqualsIfExists = { "ecs:privileged" = "false" } } },
    { Sid = "TagTaskOnlyOnRegistration", Effect = "Allow", Action = ["ecs:TagResource"], Resource = "arn:aws:ecs:${var.region}:${var.aws_account_id}:task-definition/default-sky-b-$${aws:PrincipalTag/sky:DeploymentToken}:*", Condition = { StringEquals = { "ecs:CreateAction" = "RegisterTaskDefinition" } } },
    { Sid = "PassCoreExecutionRoleToTasks", Effect = "Allow", Action = ["iam:PassRole"], Resource = data.aws_cloudformation_stack.build_consumer_core[0].outputs.ExecutionRoleArn, Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } } },
    { Sid = "PassOnlyCoreRolesToExpress", Effect = "Allow", Action = ["iam:PassRole"], Resource = [data.aws_cloudformation_stack.build_consumer_core[0].outputs.ExecutionRoleArn, data.aws_cloudformation_stack.build_consumer_core[0].outputs.InfrastructureRoleArn], Condition = { StringEquals = { "iam:PassedToService" = "ecs.amazonaws.com" } } }

    , { Sid = "PassOwnedDatabaseExecutionRole", Effect = "Allow", Action = ["iam:PassRole"], Resource = "arn:aws:iam::${var.aws_account_id}:role/sky-workload-$${aws:PrincipalTag/sky:JobId}", Condition = { StringEquals = { "iam:PassedToService" = ["ecs-tasks.amazonaws.com", "ecs.amazonaws.com"] } } },
    { Sid = "OnlyRegisteredRegion", Effect = "Deny", NotAction = ["sts:GetCallerIdentity"], Resource = "*", Condition = { StringNotEquals = { "aws:RequestedRegion" = var.region } } }
  ]) : "[]")
  deployment_tag_keys    = ["sky:OrganizationId", "sky:ApplicationId", "sky:DeploymentToken", "sky:JobId", "sky:Workspace"]
  deployment_external_id = "${var.name_prefix}-${var.aws_account_id}-${var.region}-app-deployment"
  deployment_role_registration = local.build_consumer_enabled ? {
    account_id              = var.aws_account_id, region = var.region, source_role_arn = aws_iam_role.build_worker[0].arn,
    role_arn                = aws_iam_role.app_deployment[0].arn, role_id = aws_iam_role.app_deployment[0].unique_id,
    boundary_arn            = aws_iam_policy.app_deployment_boundary[0].arn,
    core_stack_arn          = data.aws_cloudformation_stack.build_consumer_core[0].id,
    execution_role_arn      = data.aws_cloudformation_stack.build_consumer_core[0].outputs.ExecutionRoleArn,
    infrastructure_role_arn = data.aws_cloudformation_stack.build_consumer_core[0].outputs.InfrastructureRoleArn,
    external_id             = local.deployment_external_id, expires_at = try(jsondecode(var.security_effect_budget_json).expires_at, "1970-01-01T00:00:00Z")
  } : null
}
resource "aws_iam_policy" "app_deployment_boundary" {
  count  = local.build_consumer_enabled ? 1 : 0
  name   = "${var.name_prefix}-app-deployment-boundary"
  policy = jsonencode({ Version = "2012-10-17", Statement = local.broker_deployment_permissions })
  tags   = { app = "sky", "sky:purpose" = "app-deployment-boundary" }
}
resource "aws_iam_role" "app_deployment" {
  count                = local.build_consumer_enabled ? 1 : 0
  name                 = "${var.name_prefix}-app-deployment"
  permissions_boundary = aws_iam_policy.app_deployment_boundary[0].arn
  max_session_duration = 3600
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Principal = { AWS = aws_iam_role.build_worker[0].arn }, Action = ["sts:AssumeRole"], Condition = { StringEquals = { "sts:ExternalId" = local.deployment_external_id, "aws:RequestTag/sky:OrganizationId" = "personal", "aws:RequestTag/sky:Workspace" = "personal" }, Null = { for key in local.deployment_tag_keys : "aws:RequestTag/${key}" => "false" } } },
    { Effect = "Allow", Principal = { AWS = aws_iam_role.build_worker[0].arn }, Action = ["sts:TagSession"], Condition = { "ForAllValues:StringEquals" = { "aws:TagKeys" = local.deployment_tag_keys }, Null = { for key in local.deployment_tag_keys : "aws:RequestTag/${key}" => "false" } } }
  ] })
  tags = { app = "sky", "sky:purpose" = "app-scoped-deployment" }
}
resource "aws_iam_role_policy" "app_deployment" {
  count  = local.build_consumer_enabled ? 1 : 0
  role   = aws_iam_role.app_deployment[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = local.broker_deployment_permissions })
}
output "deployment_role_registration" { value = local.deployment_role_registration }
