resource "aws_kms_key" "build_signing" {
  description              = "Sky expected-input and offline inspection signatures; not proof of malware absence"
  customer_master_key_spec = "ECC_NIST_P256"
  key_usage                = "SIGN_VERIFY"
  deletion_window_in_days  = 7
  multi_region             = false
  tags                     = local.tags
}
data "aws_iam_role" "github_builder" {
  count = var.github_builder_role_name != null ? 1 : 0
  name  = var.github_builder_role_name
}
resource "aws_iam_role_policy" "github_controller" {
  count = var.github_builder_role_name != null ? 1 : 0
  name  = "${var.name}-verified-controller"
  role  = data.aws_iam_role.github_builder[0].name
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["sts:AssumeRole", "sts:TagSession"], Resource = aws_iam_role.controller.arn },
    { Effect = "Allow", Action = ["kms:DescribeKey", "kms:GetPublicKey", "kms:Sign"], Resource = aws_kms_key.build_signing.arn },
    { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${var.github_artifacts_bucket_arn}/trusted-build-materials/*", Condition = { StringEquals = { "s3:ResourceAccount" = data.aws_caller_identity.current.account_id } } }
  ] })
  lifecycle {
    precondition {
      condition     = var.github_artifacts_bucket_arn != null && startswith(data.aws_iam_role.github_builder[0].arn, "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/")
      error_message = "The registered workflow role and encrypted artifact bucket must belong to this account."
    }
  }
}
output "build_signing_key_arn" { value = aws_kms_key.build_signing.arn }
# The data-only publisher signs only with this registered key. It cannot manage
# keys, retrieve registry login tokens, execute image data or read app Secrets.
resource "aws_iam_role_policy" "publisher_signing" {
  role = aws_iam_role.publisher.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Action = ["kms:DescribeKey", "kms:GetPublicKey", "kms:Sign"], Resource = aws_kms_key.build_signing.arn
  }] })
}
