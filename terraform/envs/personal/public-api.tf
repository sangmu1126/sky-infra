locals {
  api_origin = var.enable_public_api ? "https://${aws_cloudfront_distribution.api[0].domain_name}" : null
  public_api_environment = var.enable_public_api ? merge(local.state_environment, {
    SKY_DATABASE_SECRET_ARN         = aws_secretsmanager_secret.state_api.arn
    SKY_DEPLOYMENT_CONSUMER_ENABLED = "false"
    TMPDIR                          = "/scratch/work"
    SKY_COGNITO_LOGIN_DOMAIN        = "https://${aws_cognito_user_pool_domain.api[0].domain}.auth.${var.region}.amazoncognito.com"
    SKY_COGNITO_AUTH_JSON = jsonencode({
      version = 1, issuer = "https://${aws_cognito_user_pool.api[0].endpoint}", client_id = aws_cognito_user_pool_client.api[0].id, required_scopes = ["sky/deploy"]
    })
    SKY_MEMBERSHIPS_JSON = jsonencode({
      version = 1
      members = [for member in var.api_memberships : {
        issuer  = "https://${aws_cognito_user_pool.api[0].endpoint}", subject = member.subject,
        user_id = member.user_id, organization_id = "personal", role = member.role, enabled = true
      }]
    })
  }) : {}
}
resource "aws_subnet" "public_api_task" {
  count                   = var.enable_public_api ? 1 : 0
  vpc_id                  = aws_vpc.this.id
  availability_zone       = "ap-northeast-2a"
  cidr_block              = "10.42.2.0/24"
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name_prefix}-api-runtime", "sky:tier" = "trusted-api" }
}
resource "aws_route_table_association" "public_api_task" {
  count          = var.enable_public_api ? 1 : 0
  subnet_id      = aws_subnet.public_api_task[0].id
  route_table_id = aws_route_table.bridge[0].id
}
resource "aws_security_group" "public_api_task" {
  count       = var.enable_public_api ? 1 : 0
  name        = "${var.name_prefix}-api-runtime"
  description = "Private ALB ingress only; outbound AWS HTTPS and private PostgreSQL"
  vpc_id      = aws_vpc.this.id
}
resource "aws_vpc_security_group_ingress_rule" "api_from_alb" {
  count                        = var.enable_public_api ? 1 : 0
  security_group_id            = aws_security_group.public_api_task[0].id
  referenced_security_group_id = aws_security_group.api_alb[0].id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}
resource "aws_vpc_security_group_egress_rule" "alb_to_api" {
  count                        = var.enable_public_api ? 1 : 0
  security_group_id            = aws_security_group.api_alb[0].id
  referenced_security_group_id = aws_security_group.public_api_task[0].id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}
resource "aws_vpc_security_group_egress_rule" "api_https" {
  count             = var.enable_public_api ? 1 : 0
  security_group_id = aws_security_group.public_api_task[0].id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}
resource "aws_vpc_security_group_egress_rule" "api_database" {
  count                        = var.enable_public_api ? 1 : 0
  security_group_id            = aws_security_group.public_api_task[0].id
  referenced_security_group_id = aws_security_group.database.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
resource "aws_vpc_security_group_ingress_rule" "database_from_api" {
  count                        = var.enable_public_api ? 1 : 0
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.public_api_task[0].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
resource "aws_cloudwatch_log_group" "public_api" {
  count             = var.enable_public_api ? 1 : 0
  name              = "/sky/${var.name_prefix}/api"
  retention_in_days = 7
}
resource "aws_iam_role" "public_api_execution" {
  count              = var.enable_public_api ? 1 : 0
  name               = "${var.name_prefix}-api-execution"
  assume_role_policy = local.ecs_task_trust
}
resource "aws_iam_role_policy" "public_api_execution" {
  count = var.enable_public_api ? 1 : 0
  role  = aws_iam_role.public_api_execution[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      { Effect = "Allow", Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"], Resource = data.aws_ecr_repository.outbox_image[0].arn },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.public_api[0].arn}:*" }
    ]
  })
}
resource "aws_ecs_task_definition" "public_api" {
  count                    = var.enable_public_api ? 1 : 0
  family                   = "${var.name_prefix}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.public_api_execution[0].arn
  task_role_arn            = aws_iam_role.api_task[0].arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  volume {
    name = "api-scratch" # Task-local ephemeral storage; no host path or durable app state.
  }
  container_definitions = jsonencode([{
    name            = "api", image = var.public_api_image, essential = true, user = "65534:65534", readonlyRootFilesystem = true
    command         = ["api", "--host", "0.0.0.0", "--port", "8080", "--auth-mode", "cognito", "--enable-preparation", "--origin", local.api_origin]
    environment     = [for name, value in local.public_api_environment : { name = name, value = value }]
    mountPoints     = [{ sourceVolume = "api-scratch", containerPath = "/scratch", readOnly = false }]
    systemControls  = [], volumesFrom = []
    dependsOn       = [{ containerName = "prepare-scratch", condition = "SUCCESS" }]
    portMappings    = [{ containerPort = 8080, hostPort = 8080, protocol = "tcp" }]
    linuxParameters = { capabilities = { add = [], drop = ["ALL"] } }
    stopTimeout     = 30
    healthCheck = {
      command = ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/ready', timeout=3)"], interval = 30, timeout = 5, retries = 3, startPeriod = 30
    }
    logConfiguration = {
      logDriver = "awslogs"
      options   = { awslogs-group = aws_cloudwatch_log_group.public_api[0].name, awslogs-region = var.region, awslogs-stream-prefix = "api" }
    }
    }, {
    name       = "prepare-scratch", image = var.public_api_image, essential = false
    user       = "0:0", readonlyRootFilesystem = true
    entryPoint = ["python", "-c"]
    # Root owns the fresh mount. chmod of its own directory needs no added capabilities.
    # Sticky mode and private TemporaryDirectory children match normal /tmp semantics.
    command         = ["import os; os.makedirs('/scratch/work', mode=0o1777, exist_ok=True); os.chmod('/scratch/work', 0o1777)"]
    mountPoints     = [{ sourceVolume = "api-scratch", containerPath = "/scratch", readOnly = false }]
    portMappings    = [], systemControls = [], volumesFrom = []
    linuxParameters = { capabilities = { add = [], drop = ["ALL"] } }
  }])
}
resource "aws_ecs_service" "public_api" {
  count                              = var.enable_public_api ? 1 : 0
  name                               = "${var.name_prefix}-api"
  cluster                            = aws_ecs_cluster.outbox[0].id
  task_definition                    = aws_ecs_task_definition.public_api[0].arn
  desired_count                      = 1
  launch_type                        = "FARGATE"
  platform_version                   = "1.4.0"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  enable_execute_command             = false
  wait_for_steady_state              = true
  health_check_grace_period_seconds  = 60
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.api[0].arn
    container_name   = "api"
    container_port   = 8080
  }
  network_configuration {
    subnets          = [aws_subnet.public_api_task[0].id]
    security_groups  = [aws_security_group.public_api_task[0].id]
    assign_public_ip = true # Outbound API access, ingress accepts only the private ALB SG.
  }
  depends_on = [aws_lb_listener.api, aws_iam_role_policy.public_api_execution, aws_iam_role_policy.api_task, aws_route_table_association.public_api_task, aws_vpc_security_group_ingress_rule.api_from_alb, aws_vpc_security_group_egress_rule.alb_to_api, aws_vpc_security_group_egress_rule.api_https, aws_vpc_security_group_egress_rule.api_database, aws_vpc_security_group_ingress_rule.database_from_api]
}
output "public_api" {
  value = var.enable_public_api ? {
    origin           = local.api_origin, login_url = "${local.api_origin}/login", cluster_arn = aws_ecs_cluster.outbox[0].arn,
    service_name     = aws_ecs_service.public_api[0].name, task_definition_arn = aws_ecs_task_definition.public_api[0].arn,
    image            = var.public_api_image, distribution_id = aws_cloudfront_distribution.api[0].id,
    user_pool_id     = aws_cognito_user_pool.api[0].id, client_id = aws_cognito_user_pool_client.api[0].id,
    target_group_arn = aws_lb_target_group.api[0].arn
  } : null
}
