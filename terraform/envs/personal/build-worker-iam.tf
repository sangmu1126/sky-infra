# Build-stage consumer only: consumes admitted work and dispatches the external
# builder. No service activation, user-code execution or ECS deployment grant.
resource "aws_secretsmanager_secret" "state_build" {
  count                   = var.enable_build_worker_role ? 1 : 0
  name                    = "${var.name_prefix}/state-build"
  description             = "Build consumer SQL identity; not API, publisher or administrator"
  recovery_window_in_days = 30
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role" "build_worker" {
  count              = var.enable_build_worker_role ? 1 : 0
  name               = "${var.name_prefix}-build-worker"
  assume_role_policy = local.ecs_task_trust
}

resource "aws_iam_role_policy" "build_worker" {
  count = var.enable_build_worker_role ? 1 : 0
  role  = aws_iam_role.build_worker[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadOwnDatabaseCredential", Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"], Resource = aws_secretsmanager_secret.state_build[0].arn
      },
      {
        Sid      = "ConsumeAdmittedWork", Effect = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility"]
        Resource = module.queue.queue_arn
      },
      {
        Sid       = "ReadPersonalBuildInputsAndResults", Effect = "Allow"
        Action    = ["s3:GetObject"]
        Resource  = ["${module.artifacts.bucket_arn}/sources/personal/*", "${module.artifacts.bucket_arn}/builds/*"]
        Condition = { StringEquals = { "s3:ResourceAccount" = var.aws_account_id } }
      },
      {
        Sid      = "WriteEncryptedBuildRequest", Effect = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${module.artifacts.bucket_arn}/sources/personal/*/*/build-requests/*"
        Condition = { StringEquals = {
          "s3:ResourceAccount"              = var.aws_account_id
          "s3:x-amz-server-side-encryption" = "AES256"
        } }
      },
      {
        Sid    = "VerifyAppImage", Effect = "Allow"
        Action = ["ecr:BatchGetImage"], Resource = "arn:aws:ecr:${var.region}:${var.aws_account_id}:repository/sky-managed"
      },
      {
        Sid    = "ProtectOwnClusterTask", Effect = "Allow"
        Action = ["ecs:UpdateTaskProtection"], Resource = "arn:aws:ecs:${var.region}:${var.aws_account_id}:task/${var.name_prefix}-outbox/*"
      }
    ]
  })
}

output "build_worker_environment" {
  description = "Build-stage identity references only; does not activate a worker or authorize deployment"
  value = var.enable_build_worker_role ? merge(local.state_environment, {
    SKY_DATABASE_SECRET_ARN = aws_secretsmanager_secret.state_build[0].arn
  }) : null
}
output "build_worker_role_arn" {
  value = var.enable_build_worker_role ? aws_iam_role.build_worker[0].arn : null
}
