resource "aws_iam_role" "grant_writer" {
  name                 = "${var.name}-grant-writer"
  max_session_duration = 3600
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Principal = { AWS = var.publisher_principal_arn }, Action = "sts:AssumeRole"
  }] })
  tags = local.tags
}
resource "aws_iam_role_policy" "grant_writer" {
  role = aws_iam_role.grant_writer.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect   = "Allow", Action = ["s3:GetObject", "s3:PutObject"],
    Resource = "${aws_s3_bucket.security_audit.arn}/execution-grants/*"
  }] })
}
resource "aws_iam_role_policy" "grant_reader" {
  role = aws_iam_role.publisher.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = "s3:GetObject", Resource = "${aws_s3_bucket.security_audit.arn}/execution-grants/*" },
    { Effect = "Deny", Action = ["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion"], Resource = "${aws_s3_bucket.security_audit.arn}/execution-grants/*" }
  ] })
}
output "grant_writer_role_arn" { value = aws_iam_role.grant_writer.arn }
