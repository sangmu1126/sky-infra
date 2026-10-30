# Isolated positive detection fixture. Never a real user Secret or an attack on user code.
variable "enable_security_acceptance_canary" {
  type    = bool
  default = false
  validation {
    condition     = !var.enable_security_acceptance_canary || var.enable_build_worker_preflight
    error_message = "The canary requires the existing private trusted runtime."
  }
}
variable "security_canary_read_enabled" {
  type    = bool
  default = false
}
locals {
  security_canary_code = "import boto3,json,os; s=boto3.client('secretsmanager'); r=s.get_secret_value(SecretId=os.environ['SKY_CANARY_SECRET_ARN']); assert r['SecretString']=='synthetic security observation canary'; print(json.dumps({'status':'controlled_canary_read_completed','secret_value_logged':False}))"
}
resource "aws_secretsmanager_secret" "security_canary" {
  count                   = var.enable_security_acceptance_canary ? 1 : 0
  name                    = "${var.name_prefix}/security-acceptance-canary"
  description             = "Non-sensitive constant for controlled security observation validation only"
  recovery_window_in_days = 7
  tags                    = { app = "sky", "sky:purpose" = "non-sensitive-security-canary" }
}
resource "aws_iam_role" "security_canary" {
  count              = var.enable_security_acceptance_canary ? 1 : 0
  name               = "${var.name_prefix}-security-canary"
  assume_role_policy = local.ecs_task_trust
  tags               = { app = "sky", "sky:purpose" = "security-acceptance-only" }
}
resource "aws_iam_role_policy" "security_canary" {
  count  = var.enable_security_acceptance_canary ? 1 : 0
  role   = aws_iam_role.security_canary[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = var.security_canary_read_enabled ? "Allow" : "Deny", Action = ["secretsmanager:GetSecretValue"], Resource = aws_secretsmanager_secret.security_canary[0].arn }] })
}
resource "aws_ecs_task_definition" "security_canary" {
  count                    = var.enable_security_acceptance_canary ? 1 : 0
  family                   = "${var.name_prefix}-security-canary"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.build_worker_execution[0].arn
  task_role_arn            = aws_iam_role.security_canary[0].arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name             = "canary", image = var.build_worker_image, essential = true, user = "65534:65534", readonlyRootFilesystem = true
    entryPoint       = ["python", "-c"], command = [local.security_canary_code]
    environment      = [{ name = "SKY_CANARY_SECRET_ARN", value = aws_secretsmanager_secret.security_canary[0].arn }]
    mountPoints      = [], portMappings = [], systemControls = [], volumesFrom = []
    linuxParameters  = { capabilities = { add = [], drop = ["ALL"] } }
    healthCheck      = { command = ["CMD", "python", "-c", "pass"], interval = 30, timeout = 5, retries = 1 }
    logConfiguration = { logDriver = "awslogs", options = { awslogs-group = aws_cloudwatch_log_group.build_worker[0].name, awslogs-region = var.region, awslogs-stream-prefix = "security-canary" } }
  }])
}
output "security_canary" {
  value = var.enable_security_acceptance_canary ? { role_arn = aws_iam_role.security_canary[0].arn, role_id = aws_iam_role.security_canary[0].unique_id, secret_arn = aws_secretsmanager_secret.security_canary[0].arn, task_definition_arn = aws_ecs_task_definition.security_canary[0].arn, source_digest = sha256(local.security_canary_code), read_enabled = var.security_canary_read_enabled } : null
}
