data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  tags = { app = "sky", "sky:SandboxProfile" = var.name, "sky:Purpose" = "isolated-build-control" }
}

resource "aws_vpc" "sandbox" {
  cidr_block           = "10.242.0.0/24"
  enable_dns_support   = false
  enable_dns_hostnames = false
  tags                 = merge(local.tags, { Name = var.name })
}
resource "aws_subnet" "sandbox" {
  vpc_id                  = aws_vpc.sandbox.id
  cidr_block              = "10.242.0.0/28"
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false
  tags                    = local.tags
}
resource "aws_internet_gateway" "ssh" {
  vpc_id = aws_vpc.sandbox.id
  tags   = local.tags
}
resource "aws_route_table" "ssh" {
  vpc_id = aws_vpc.sandbox.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.ssh.id
  }
  tags = local.tags
}
resource "aws_route_table_association" "ssh" {
  subnet_id      = aws_subnet.sandbox.id
  route_table_id = aws_route_table.ssh.id
}
resource "aws_security_group" "sandbox" {
  name_prefix = "${var.name}-"
  description = "One disposable VM: operator SSH ingress, no outbound traffic"
  vpc_id      = aws_vpc.sandbox.id
  ingress {
    description = "Operator control only; no public application listener"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }
  egress = []
  tags   = local.tags
}
resource "aws_ecr_repository" "sandbox" {
  name                 = "${var.name}-images"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
  tags = local.tags
}
resource "aws_sqs_queue" "review" {
  name                       = "${var.name}-review"
  sqs_managed_sse_enabled    = true
  message_retention_seconds  = 1209600
  visibility_timeout_seconds = 60
  tags                       = local.tags
}
resource "aws_sqs_queue_policy" "review" {
  queue_url = aws_sqs_queue.review.url
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Sid      = "DenyInsecureTransport", Effect = "Deny", Principal = "*", Action = "sqs:*",
    Resource = aws_sqs_queue.review.arn, Condition = { Bool = { "aws:SecureTransport" = "false" } }
  }] })
}
resource "aws_cloudwatch_log_group" "reaper" {
  name              = "/aws/lambda/${var.name}-reaper"
  retention_in_days = 14
  tags              = local.tags
}
resource "aws_iam_role" "reaper" {
  name = "${var.name}-reaper"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole"
  }] })
  tags = local.tags
}
resource "aws_iam_role_policy" "reaper" {
  role = aws_iam_role.reaper.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ec2:DescribeInstances"], Resource = "*" },
    { Effect   = "Allow", Action = ["ec2:TerminateInstances"],
      Resource = "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/*",
    Condition = { StringEquals = { "ec2:ResourceTag/app" = "sky", "ec2:ResourceTag/sky:SandboxProfile" = var.name } } },
    { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = aws_sqs_queue.review.arn },
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.reaper.arn}:*" }
  ] })
}
resource "aws_lambda_function" "reaper" {
  function_name                  = "${var.name}-reaper"
  role                           = aws_iam_role.reaper.arn
  runtime                        = "python3.12"
  handler                        = "sandbox_reaper.handler"
  filename                       = var.reaper_package
  source_code_hash               = filebase64sha256(var.reaper_package)
  timeout                        = 30
  memory_size                    = 128
  reserved_concurrent_executions = 1
  environment {
    variables = {
      SKY_SANDBOX_PROFILE = var.name
      SKY_SANDBOX_VPC     = aws_vpc.sandbox.id
      SKY_SANDBOX_GROUP   = aws_security_group.sandbox.id
      SKY_MAX_LIFETIME    = tostring(var.max_lifetime_seconds)
      SKY_REVIEW_QUEUE    = aws_sqs_queue.review.url
      SKY_ACCOUNT_ID      = data.aws_caller_identity.current.account_id
    }
  }
  tags       = local.tags
  depends_on = [aws_iam_role_policy.reaper, aws_cloudwatch_log_group.reaper]
}
resource "aws_scheduler_schedule_group" "sandbox" {
  name = var.name
  tags = local.tags
}
resource "aws_iam_role" "scheduler" {
  name = "${var.name}-deadline"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Principal = { Service = "scheduler.amazonaws.com" }, Action = "sts:AssumeRole",
    Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id },
    ArnEquals = { "aws:SourceArn" = aws_scheduler_schedule_group.sandbox.arn } }
  }] })
  tags = local.tags
}
resource "aws_iam_role_policy" "scheduler" {
  role = aws_iam_role.scheduler.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = aws_lambda_function.reaper.arn },
    { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = aws_sqs_queue.review.arn }
  ] })
}
resource "aws_scheduler_schedule" "sweep" {
  name                = "expired-builds"
  group_name          = aws_scheduler_schedule_group.sandbox.name
  schedule_expression = "rate(5 minutes)"
  flexible_time_window { mode = "OFF" }
  target {
    arn      = aws_lambda_function.reaper.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ mode = "sweep" })
    dead_letter_config { arn = aws_sqs_queue.review.arn }
    retry_policy {
      maximum_event_age_in_seconds = 300
      maximum_retry_attempts       = 2
    }
  }
  depends_on = [aws_iam_role_policy.scheduler]
}

# The publisher receives a temporary, repository-scoped role. It never needs a
# registry login token, Docker daemon, source access or execution permission.
resource "aws_iam_role" "publisher" {
  name                 = "${var.name}-publisher"
  max_session_duration = 3600
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Principal = { AWS = var.publisher_principal_arn }, Action = "sts:AssumeRole"
  }] })
  lifecycle {
    precondition {
      condition     = startswith(var.publisher_principal_arn, "arn:aws:iam::${data.aws_caller_identity.current.account_id}:")
      error_message = "Sandbox publisher principal must belong to the registered account."
    }
  }
  tags = local.tags
}
resource "aws_iam_role_policy" "publisher" {
  role = aws_iam_role.publisher.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Resource = aws_ecr_repository.sandbox.arn, Action = [
      "ecr:DescribeRepositories", "ecr:ListTagsForResource", "ecr:DescribeImages",
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage"
    ] },
    { Effect = "Deny", Resource = "*", Action = ["ecr:GetAuthorizationToken"] }
  ] })
}
