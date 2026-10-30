# One-shot, trusted preflight only. No ECS service or queue consumer is created.
data "aws_ecr_repository" "build_worker_runtime" {
  count = var.enable_build_worker_preflight ? 1 : 0
  name  = "sky-platform"
}
resource "aws_subnet" "build_worker" {
  count                   = var.enable_build_worker_preflight ? 1 : 0
  vpc_id                  = aws_vpc.this.id
  availability_zone       = "ap-northeast-2a"
  cidr_block              = "10.42.3.0/24"
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name_prefix}-build-worker", "sky:tier" = "build-worker" }
}
resource "aws_route_table_association" "build_worker" {
  count          = var.enable_build_worker_preflight ? 1 : 0
  subnet_id      = aws_subnet.build_worker[0].id
  route_table_id = aws_route_table.bridge[0].id
}
resource "aws_security_group" "build_worker" {
  count       = var.enable_build_worker_preflight ? 1 : 0
  name        = "${var.name_prefix}-build-worker"
  description = "No ingress; trusted worker AWS HTTPS and private DB egress"
  vpc_id      = aws_vpc.this.id
}
resource "aws_vpc_security_group_egress_rule" "build_worker_https" {
  count             = var.enable_build_worker_preflight ? 1 : 0
  security_group_id = aws_security_group.build_worker[0].id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}
resource "aws_vpc_security_group_egress_rule" "build_worker_database" {
  count                        = var.enable_build_worker_preflight ? 1 : 0
  security_group_id            = aws_security_group.build_worker[0].id
  referenced_security_group_id = aws_security_group.database.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
resource "aws_vpc_security_group_ingress_rule" "database_from_build_worker" {
  count                        = var.enable_build_worker_preflight ? 1 : 0
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.build_worker[0].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
resource "aws_cloudwatch_log_group" "build_worker" {
  count             = var.enable_build_worker_preflight ? 1 : 0
  name              = "/sky/${var.name_prefix}/build-worker"
  retention_in_days = 7
}
resource "aws_iam_role" "build_worker_execution" {
  count              = var.enable_build_worker_preflight ? 1 : 0
  name               = "${var.name_prefix}-build-worker-execution"
  assume_role_policy = local.ecs_task_trust
}
resource "aws_iam_role_policy" "build_worker_execution" {
  count = var.enable_build_worker_preflight ? 1 : 0
  role  = aws_iam_role.build_worker_execution[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      { Effect = "Allow", Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"], Resource = data.aws_ecr_repository.build_worker_runtime[0].arn },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.build_worker[0].arn}:*" }
    ]
  })
}
resource "aws_ecs_task_definition" "build_worker_preflight" {
  count                    = var.enable_build_worker_preflight ? 1 : 0
  family                   = "${var.name_prefix}-build-worker-preflight"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.build_worker_execution[0].arn
  task_role_arn            = aws_iam_role.build_worker[0].arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name       = "preflight", image = var.build_worker_image, essential = true
    user       = "65534:65534", readonlyRootFilesystem = true
    entryPoint = ["python", "-c"]
    command    = [file("${path.module}/../../../scripts/build_worker_preflight.py")]
    environment = [for name, value in merge(local.state_environment, local.security_runtime_environment, {
      SKY_DATABASE_SECRET_ARN            = aws_secretsmanager_secret.state_build[0].arn
      SKY_PREFLIGHT_FORBIDDEN_SECRET_ARN = aws_secretsmanager_secret.state_api.arn
      SKY_BUILDER_REPOSITORY             = "sangmu1126/sky-builder"
      SKY_BUILDER_REF                    = "main"
      SKY_BUILDER_SHA                    = var.build_worker_builder_sha
      SKY_BUILDER_PLATFORM_SHA           = var.build_worker_platform_sha
    }) : { name = name, value = value }]
    # No injected application code, private key, long-lived key, mount or listener.
    mountPoints     = [], portMappings = [], systemControls = [], volumesFrom = []
    linuxParameters = { capabilities = { add = [], drop = ["ALL"] } }
    # Disable the hosted image's HTTP health check for this one-shot command.
    healthCheck = { command = ["CMD", "python", "-c", "pass"], interval = 30, timeout = 5, retries = 1 }
    logConfiguration = {
      logDriver = "awslogs"
      options   = { awslogs-group = aws_cloudwatch_log_group.build_worker[0].name, awslogs-region = var.region, awslogs-stream-prefix = "preflight" }
    }
  }])
}
output "build_worker_preflight" {
  description = "One-shot preflight references, not an active build/deployment service"
  value = var.enable_build_worker_preflight ? {
    cluster_arn         = aws_ecs_cluster.outbox[0].arn
    task_definition_arn = aws_ecs_task_definition.build_worker_preflight[0].arn
    subnet_id           = aws_subnet.build_worker[0].id
    security_group_id   = aws_security_group.build_worker[0].id
    image               = var.build_worker_image
    log_group           = aws_cloudwatch_log_group.build_worker[0].name
  } : null
}
