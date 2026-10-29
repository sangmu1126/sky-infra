variable "name" {
  type = string
  validation {
    condition     = can(regex("^sky-[a-z0-9-]{1,28}$", var.name))
    error_message = "A dedicated Sky sandbox prefix is required."
  }
}
variable "ssh_cidr" {
  type = string
  validation {
    condition     = can(cidrhost(var.ssh_cidr, 0)) && endswith(var.ssh_cidr, "/32")
    error_message = "Only the operator's single IPv4 address is allowed."
  }
}
variable "availability_zone" { type = string }
variable "reaper_package" { type = string }
variable "max_lifetime_seconds" {
  type    = number
  default = 1800
  validation {
    condition     = var.max_lifetime_seconds >= 180 && var.max_lifetime_seconds <= 1800 && floor(var.max_lifetime_seconds) == var.max_lifetime_seconds
    error_message = "The external lifetime bound must be 180..1800 seconds."
  }
}
variable "publisher_principal_arn" {
  type = string
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:(role|user)/[A-Za-z0-9+=,.@_/-]+$", var.publisher_principal_arn))
    error_message = "An explicit trusted control-plane IAM principal is required."
  }
}
variable "audit_organization_id" {
  type    = string
  default = "security-validation"
  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,128}$", var.audit_organization_id))
    error_message = "Explicit audit organization scope required."
  }
}
variable "audit_application_id" {
  type    = string
  default = "defense-validation"
  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,128}$", var.audit_application_id))
    error_message = "Explicit audit application scope required."
  }
}
variable "trusted_ami_id" {
  type    = string
  default = "ami-0c0f01658064f93a8"
  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.trusted_ami_id))
    error_message = "Pin an independently checked ECS-optimized AMI in this region."
  }
}
variable "github_builder_role_name" {
  type    = string
  default = null
  validation {
    condition     = var.github_builder_role_name == null || can(regex("^sky-[A-Za-z0-9-]+-app-builder$", var.github_builder_role_name))
    error_message = "Register the existing same-account workflow role, not an arbitrary principal."
  }
}
variable "github_artifacts_bucket_arn" {
  type    = string
  default = null
  validation {
    condition     = var.github_artifacts_bucket_arn == null || can(regex("^arn:aws:s3:::sky-[a-z0-9-]+$", var.github_artifacts_bucket_arn))
    error_message = "Register an exact Sky artifact bucket ARN."
  }
}
