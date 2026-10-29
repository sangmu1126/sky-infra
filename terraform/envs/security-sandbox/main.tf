terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}
variable "aws_account_id" { type = string }
variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}
variable "operator_ssh_cidr" { type = string }
variable "publisher_principal_arn" { type = string }
variable "github_builder_role_name" {
  type    = string
  default = null
}
variable "github_artifacts_bucket_arn" {
  type    = string
  default = null
}
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]
}
module "sandbox" {
  source                      = "../../modules/isolated-build"
  name                        = "sky-security-build"
  publisher_principal_arn     = var.publisher_principal_arn
  github_builder_role_name    = var.github_builder_role_name
  github_artifacts_bucket_arn = var.github_artifacts_bucket_arn
  ssh_cidr                    = var.operator_ssh_cidr
  availability_zone           = "${var.aws_region}a"
  reaper_package              = "${path.module}/.terraform/sandbox-reaper.zip"
}
output "sandbox_profile" { value = module.sandbox.profile }

output "publisher_role_arn" { value = module.sandbox.publisher_role_arn }
output "audit_bucket" { value = module.sandbox.audit_bucket }
output "audit_writer_role_arn" { value = module.sandbox.audit_writer_role_arn }

output "collector_role_arn" { value = module.sandbox.collector_role_arn }
output "grant_writer_role_arn" { value = module.sandbox.grant_writer_role_arn }
output "controller_role_arn" { value = module.sandbox.controller_role_arn }

output "build_signing_key_arn" { value = module.sandbox.build_signing_key_arn }
