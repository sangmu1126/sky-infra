# Separate credentials for trusted prepare/publish jobs. The user-code build job
# has no OIDC permission; creating this role does not start a workflow or consumer.
data "aws_iam_openid_connect_provider" "builder" {
  count = var.enable_builder_role ? 1 : 0
  arn   = "arn:aws:iam::${var.aws_account_id}:oidc-provider/token.actions.githubusercontent.com"
}

data "aws_ecr_repository" "builder" {
  count = var.enable_builder_role ? 1 : 0
  name  = "sky-managed" # Existing app-image repository, not the Sky service image.
}

resource "aws_iam_role" "builder" {
  count                = var.enable_builder_role ? 1 : 0
  name                 = "${var.name_prefix}-app-builder"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = data.aws_iam_openid_connect_provider.builder[0].arn }
      Condition = { StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = var.builder_oidc_subject
      } }
    }]
  })
  lifecycle {
    precondition {
      condition     = contains(data.aws_iam_openid_connect_provider.builder[0].client_id_list, "sts.amazonaws.com")
      error_message = "The existing GitHub OIDC provider must allow the STS audience."
    }
  }
}

resource "aws_iam_role_policy" "builder" {
  count = var.enable_builder_role ? 1 : 0
  role  = aws_iam_role.builder[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "NoRegistryLoginToken", Effect = "Deny"
        Action = ["ecr:GetAuthorizationToken"], Resource = "*"
      },
      {
        Sid      = "PublishAppImages", Effect = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages", "ecr:DescribeRepositories", "ecr:ListTagsForResource"]
        Resource = data.aws_ecr_repository.builder[0].arn
      },
      {
        Sid       = "ReadPersonalSources", Effect = "Allow"
        Action    = ["s3:GetObject"]
        Resource  = ["${module.artifacts.bucket_arn}/sources/personal/*", "${module.artifacts.bucket_arn}/execution-grants/*"]
        Condition = { StringEquals = { "s3:ResourceAccount" = var.aws_account_id } }
      },
      {
        Sid      = "WriteEncryptedBuildResults", Effect = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${module.artifacts.bucket_arn}/builds/*"
        Condition = { StringEquals = {
          "s3:ResourceAccount"              = var.aws_account_id
          "s3:x-amz-server-side-encryption" = "AES256"
        } }
      }
    ]
  })
}

output "builder_role_arn" {
  description = "Prepare/publish role only; does not establish GitHub App or worker readiness"
  value       = var.enable_builder_role ? aws_iam_role.builder[0].arn : null
}

# Outer workflow role can assume only this registered controller. The latter
# requires a job session tag and cannot access S3, ECR, KMS or application roles.
resource "aws_iam_role_policy" "builder_controller" {
  count = var.enable_builder_role && var.builder_controller_role_arn != null ? 1 : 0
  role  = aws_iam_role.builder[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["sts:AssumeRole", "sts:TagSession"], Resource = var.builder_controller_role_arn },
    { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${module.artifacts.bucket_arn}/trusted-build-materials/*" }
  ] })
}
resource "aws_iam_role_policy" "builder_signing" {
  count = var.enable_builder_role && var.builder_signing_key_arn != null ? 1 : 0
  role  = aws_iam_role.builder[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Action = ["kms:DescribeKey", "kms:GetPublicKey", "kms:Sign"], Resource = var.builder_signing_key_arn
  }] })
}
