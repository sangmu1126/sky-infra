# API AWS access is independent from its PostgreSQL grants and the publisher role.
resource "aws_iam_role" "api_task" {
  count                = var.enable_api_role ? 1 : 0
  name                 = "${var.name_prefix}-api-task"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(jsondecode(local.ecs_task_trust).Statement, var.api_operator_principal_arn == null ? [] : [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = var.api_operator_principal_arn }
    }])
  })
}

resource "aws_iam_role_policy" "api_task" {
  count = var.enable_api_role ? 1 : 0
  role  = aws_iam_role.api_task[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadApiDatabaseCredential"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.state_api.arn
      },
      {
        Sid       = "ReadWorkspaceSource"
        Effect    = "Allow"
        Action    = ["s3:GetObject"]
        Resource  = "${module.artifacts.bucket_arn}/sources/${local.state_environment.SKY_STATE_WORKSPACE}/*"
        Condition = { StringEquals = { "s3:ResourceAccount" = var.aws_account_id } }
      },
      {
        Sid      = "WriteEncryptedWorkspaceSource"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${module.artifacts.bucket_arn}/sources/${local.state_environment.SKY_STATE_WORKSPACE}/*"
        Condition = { StringEquals = {
          "s3:ResourceAccount"              = var.aws_account_id
          "s3:x-amz-server-side-encryption" = "AES256"
        } }
      }
    ]
  })
}

output "api_task_role_arn" {
  description = "API runtime role; no deployment, publisher or database administrator permissions"
  value       = var.enable_api_role ? aws_iam_role.api_task[0].arn : null
}
