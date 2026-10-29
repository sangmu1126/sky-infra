resource "aws_iam_role" "security_collector" {
  name                 = "${var.name}-collector"
  max_session_duration = 3600
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Principal = { AWS = var.publisher_principal_arn }, Action = "sts:AssumeRole"
  }] })
  tags = local.tags
}
resource "aws_iam_role_policy" "security_collector" {
  role = aws_iam_role.security_collector.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = "cloudtrail:LookupEvents", Resource = "*",
    Condition = { StringEquals = { "aws:RequestedRegion" = data.aws_region.current.region } } },
    { Effect = "Allow", Action = "sts:AssumeRole", Resource = aws_iam_role.audit_writer.arn },
    { Effect = "Allow", Action = ["sqs:GetQueueAttributes", "sqs:ListQueueTags", "sqs:SendMessage"], Resource = aws_sqs_queue.review.arn },
    { Effect = "Deny", Action = ["secretsmanager:GetSecretValue", "ssm:GetParameter", "ssm:GetParameters", "kms:Decrypt"], Resource = "*" }
  ] })
}
output "collector_role_arn" { value = aws_iam_role.security_collector.arn }
