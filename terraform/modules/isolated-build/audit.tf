resource "aws_s3_bucket" "security_audit" {
  bucket        = "sky-security-audit-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"
  force_destroy = false
  tags          = merge(local.tags, { "sky:Purpose" = "security-audit" })
}
resource "aws_s3_bucket_public_access_block" "security_audit" {
  bucket                  = aws_s3_bucket.security_audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_versioning" "security_audit" {
  bucket = aws_s3_bucket.security_audit.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "security_audit" {
  bucket = aws_s3_bucket.security_audit.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_lifecycle_configuration" "security_audit" {
  bucket = aws_s3_bucket.security_audit.id
  rule {
    id     = "bounded-audit-retention"
    status = "Enabled"
    filter { prefix = "audit/" }
    expiration { days = 14 }
    noncurrent_version_expiration { noncurrent_days = 7 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
  depends_on = [aws_s3_bucket_versioning.security_audit]
}
resource "aws_s3_bucket_policy" "security_audit" {
  bucket = aws_s3_bucket.security_audit.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [aws_s3_bucket.security_audit.arn, "${aws_s3_bucket.security_audit.arn}/*"],
    Condition = { Bool = { "aws:SecureTransport" = "false" } } },
    { Effect = "Deny", Principal = "*", Action = "s3:PutObject", Resource = "${aws_s3_bucket.security_audit.arn}/audit/*",
    Condition = { Null = { "s3:if-none-match" = "true" } } }
  ] })
}
resource "aws_iam_role" "audit_writer" {
  name                 = "${var.name}-audit-writer"
  max_session_duration = 3600
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Principal = { AWS = [var.publisher_principal_arn, aws_iam_role.security_collector.arn] }, Action = "sts:AssumeRole"
  }] })
  tags = local.tags
}
resource "aws_iam_role_policy" "audit_writer" {
  role = aws_iam_role.audit_writer.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = "s3:PutObject", Resource = "${aws_s3_bucket.security_audit.arn}/audit/${var.audit_organization_id}/${var.audit_application_id}/*" },
    { Effect = "Deny", Action = ["s3:DeleteObject", "s3:DeleteObjectVersion", "s3:GetObject", "s3:GetObjectVersion", "s3:PutBucketPolicy", "s3:PutLifecycleConfiguration"], Resource = "*" }
  ] })
}
output "audit_bucket" { value = aws_s3_bucket.security_audit.id }
output "audit_writer_role_arn" { value = aws_iam_role.audit_writer.arn }
