terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.0" }
  }
}
variable "name" {
  type = string
  validation {
    condition     = can(regex("^sky-[a-z0-9-]{1,59}$", var.name))
    error_message = "A bounded owned role name is required."
  }
}
variable "account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Exact account required."
  }
}
variable "region" {
  type = string
  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.region))
    error_message = "Exact AWS region required."
  }
}
variable "organization_id" {
  type = string
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", var.organization_id))
    error_message = "Exact bounded organization/application identity required."
  }
}
variable "application_id" {
  type = string
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", var.application_id))
    error_message = "Exact bounded organization/application identity required."
  }
}
variable "external_id" {
  description = "Operator-generated deputy binding, not a secret or application-supplied value."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9_:-]{32,128}$", var.external_id))
    error_message = "Bounded operator external ID required."
  }
}
variable "source_principal_arn" {
  type = string
  validation {
    condition     = can(regex("^arn:aws:iam::${var.account_id}:(user|role)/[A-Za-z0-9+=,.@_/-]+$", var.source_principal_arn))
    error_message = "Only an exact same-account trusted control-plane principal is accepted."
  }
}
variable "owned_secret_arns" {
  type = list(string)
  validation {
    condition     = length(var.owned_secret_arns) > 0 && length(var.owned_secret_arns) <= 16 && alltrue([for arn in var.owned_secret_arns : can(regex("^arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:[A-Za-z0-9/_+=.!@-]+-[A-Za-z0-9]{6}$", arn))])
    error_message = "Exact same-account/region application Secret ARNs are required; no wildcards."
  }
}
variable "secret_kms_key_arn" {
  type = string
  validation {
    condition     = can(regex("^arn:aws:kms:${var.region}:${var.account_id}:key/[a-f0-9-]{36}$", var.secret_kms_key_arn))
    error_message = "Exact same-account/region secret encryption key required."
  }
}
variable "tags" {
  type    = map(string)
  default = {}
}
data "aws_caller_identity" "current" {}
locals {
  scope = { "sky:OrganizationId" = var.organization_id, "sky:ApplicationId" = var.application_id }
  permissions = {
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"], Resource = var.owned_secret_arns,
      Condition = { StringEquals = { "aws:PrincipalTag/sky:OrganizationId" = var.organization_id, "aws:PrincipalTag/sky:ApplicationId" = var.application_id } } },
      { Effect = "Allow", Action = ["kms:Decrypt"], Resource = [var.secret_kms_key_arn], Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${var.region}.amazonaws.com", "kms:EncryptionContext:SecretARN" = var.owned_secret_arns } } },
      { Effect = "Deny", Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"], NotResource = var.owned_secret_arns },
      { Effect = "Deny", NotAction = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret", "kms:Decrypt", "sts:GetCallerIdentity"], Resource = "*" },
      { Effect = "Deny", NotAction = ["sts:GetCallerIdentity"], Resource = "*", Condition = { StringNotEquals = { "aws:RequestedRegion" = var.region } } }
    ]
  }
}
resource "aws_iam_policy" "boundary" {
  name   = "${var.name}-boundary"
  policy = jsonencode(local.permissions)
  tags   = merge(var.tags, local.scope, { app = "sky" })
}
resource "aws_iam_role" "application" {
  name                 = var.name
  max_session_duration = 3600
  permissions_boundary = aws_iam_policy.boundary.arn
  # ExternalId belongs to AssumeRole, not the permissions-only TagSession check.
  # Both statements retain the exact source and required tenant/app tag values.
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [
    {
      Effect    = "Allow", Principal = { AWS = var.source_principal_arn }, Action = ["sts:AssumeRole"],
      Condition = { StringEquals = { "sts:ExternalId" = var.external_id, "aws:RequestTag/sky:OrganizationId" = var.organization_id, "aws:RequestTag/sky:ApplicationId" = var.application_id } }
    },
    {
      Effect = "Allow", Principal = { AWS = var.source_principal_arn }, Action = ["sts:TagSession"],
      Condition = {
        StringEquals                = { "aws:RequestTag/sky:OrganizationId" = var.organization_id, "aws:RequestTag/sky:ApplicationId" = var.application_id },
        "ForAllValues:StringEquals" = { "aws:TagKeys" = ["sky:OrganizationId", "sky:ApplicationId"] }
      }
    }
  ] })
  tags = merge(var.tags, local.scope, { app = "sky" })
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.account_id
      error_message = "Do not provision delegation in an unregistered account."
    }
  }
}
resource "aws_iam_role_policy" "application" {
  role   = aws_iam_role.application.name
  policy = jsonencode(local.permissions)
}
output "registration" {
  value = { organization_id = var.organization_id, application_id = var.application_id, account_id = var.account_id, region = var.region, source_principal_arn = var.source_principal_arn, role_arn = aws_iam_role.application.arn, role_id = aws_iam_role.application.unique_id, external_id = var.external_id, boundary_arn = aws_iam_policy.boundary.arn,
    statements_json = jsonencode([
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"], Resource = var.owned_secret_arns },
      { Effect = "Allow", Action = ["kms:Decrypt"], Resource = [var.secret_kms_key_arn], Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${var.region}.amazonaws.com", "kms:EncryptionContext:SecretARN" = var.owned_secret_arns } } }
  ]) }
}
output "boundary_arn" { value = aws_iam_policy.boundary.arn }
