# Trusted publisher only. No user code, Docker socket, public listener or deployment permissions.
locals {
  ecs_task_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ecs-tasks.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.aws_account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:ecs:${var.region}:${var.aws_account_id}:*" }
      }
    }]
  })
}

data "aws_ecr_repository" "outbox_image" {
  count = var.enable_outbox_service ? 1 : 0
  name  = "sky-platform"
}

resource "aws_subnet" "publisher" {
  count                   = var.enable_outbox_service ? 1 : 0
  vpc_id                  = aws_vpc.this.id
  availability_zone       = "ap-northeast-2a"
  cidr_block              = "10.42.1.0/24"
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name_prefix}-publisher", "sky:tier" = "publisher" }
}

resource "aws_route_table_association" "publisher" {
  count          = var.enable_outbox_service ? 1 : 0
  subnet_id      = aws_subnet.publisher[0].id
  route_table_id = aws_route_table.bridge[0].id
}

resource "aws_security_group" "publisher" {
  count       = var.enable_outbox_service ? 1 : 0
  name        = "${var.name_prefix}-publisher"
  description = "No ingress; AWS HTTPS and private PostgreSQL egress only"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_egress_rule" "publisher_https" {
  count             = var.enable_outbox_service ? 1 : 0
  security_group_id = aws_security_group.publisher[0].id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "publisher_database" {
  count                        = var.enable_outbox_service ? 1 : 0
  security_group_id            = aws_security_group.publisher[0].id
  referenced_security_group_id = aws_security_group.database.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "database_from_publisher" {
  count                        = var.enable_outbox_service ? 1 : 0
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.publisher[0].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_iam_role" "outbox_task" {
  count              = var.enable_outbox_service ? 1 : 0
  name               = "${var.name_prefix}-outbox-task"
  assume_role_policy = local.ecs_task_trust
}

resource "aws_iam_role_policy" "outbox_task" {
  count = var.enable_outbox_service ? 1 : 0
  role  = aws_iam_role.outbox_task[0].id
  name  = "PublisherOnly"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = aws_secretsmanager_secret.state_outbox.arn },
      { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = module.queue.queue_arn }
    ]
  })
}

resource "aws_cloudwatch_log_group" "outbox" {
  count             = var.enable_outbox_service ? 1 : 0
  name              = "/sky/${var.name_prefix}/outbox"
  retention_in_days = 7
}

resource "aws_iam_role" "outbox_execution" {
  count              = var.enable_outbox_service ? 1 : 0
  name               = "${var.name_prefix}-outbox-execution"
  assume_role_policy = local.ecs_task_trust
}

resource "aws_iam_role_policy" "outbox_execution" {
  count = var.enable_outbox_service ? 1 : 0
  role  = aws_iam_role.outbox_execution[0].id
  name  = "PullReviewedImageAndWriteLogs"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      { Effect = "Allow", Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"], Resource = data.aws_ecr_repository.outbox_image[0].arn },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.outbox[0].arn}:*" }
    ]
  })
}

resource "aws_ecs_cluster" "outbox" {
  count = var.enable_outbox_service ? 1 : 0
  name  = "${var.name_prefix}-outbox"
}

resource "aws_ecs_task_definition" "outbox" {
  count                    = var.enable_outbox_service ? 1 : 0
  family                   = "${var.name_prefix}-outbox"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.outbox_execution[0].arn
  task_role_arn            = aws_iam_role.outbox_task[0].arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name    = "outbox", image = var.outbox_service_image, essential = true
    user    = "65534:65534", readonlyRootFilesystem = true
    command = ["worker", "--mode", "outbox", "--interval", "15"]
    environment = [for name, value in merge(local.state_environment, local.security_runtime_environment, {
      SKY_DATABASE_SECRET_ARN = aws_secretsmanager_secret.state_outbox.arn
    }) : { name = name, value = value }]
    # Match the ECS API's explicit empty defaults to avoid perpetual task revisions.
    mountPoints     = []
    portMappings    = []
    systemControls  = []
    volumesFrom     = []
    linuxParameters = { capabilities = { add = [], drop = ["ALL"] } }
    stopTimeout     = 30
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group = aws_cloudwatch_log_group.outbox[0].name, awslogs-region = var.region, awslogs-stream-prefix = "publisher"
      }
    }
  }])
}

resource "aws_ecs_service" "outbox" {
  count                              = var.enable_outbox_service ? 1 : 0
  name                               = "${var.name_prefix}-outbox"
  cluster                            = aws_ecs_cluster.outbox[0].id
  task_definition                    = aws_ecs_task_definition.outbox[0].arn
  desired_count                      = 1
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
    subnets          = [aws_subnet.publisher[0].id]
    security_groups  = [aws_security_group.publisher[0].id]
    assign_public_ip = true # Outbound AWS API access only; SG has no ingress.
  }
  depends_on = [aws_iam_role_policy.outbox_task, aws_iam_role_policy.outbox_execution, aws_route.bridge_outbound, aws_route_table_association.publisher, aws_vpc_security_group_egress_rule.publisher_https, aws_vpc_security_group_egress_rule.publisher_database, aws_vpc_security_group_ingress_rule.database_from_publisher]
}

output "outbox_service" {
  value = var.enable_outbox_service ? {
    cluster_arn         = aws_ecs_cluster.outbox[0].arn
    service_name        = aws_ecs_service.outbox[0].name
    task_role_arn       = aws_iam_role.outbox_task[0].arn
    task_definition_arn = aws_ecs_task_definition.outbox[0].arn
    log_group           = aws_cloudwatch_log_group.outbox[0].name
    image               = var.outbox_service_image
  } : null
}
