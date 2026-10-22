variable "aws_account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "Supply the expected personal AWS account explicitly."
  }
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
  validation {
    condition     = var.region == "ap-northeast-2"
    error_message = "This personal subnet layout currently supports Seoul only."
  }
}

variable "name_prefix" {
  type    = string
  default = "sky-personal"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,29}$", var.name_prefix))
    error_message = "Use a bounded lowercase resource prefix."
  }
}

variable "postgres_version" {
  type    = string
  default = "17.9"
}

variable "state_db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "state_db_multi_az" {
  description = "Personal capacity default; not a claim of high availability"
  type        = bool
  default     = false
}
variable "enable_ssm_bridge" {
  description = "Explicitly enable the no-ingress private management bridge"
  type        = bool
  default     = false
}

variable "ssm_bridge_ami_id" {
  description = "Operator-pinned Amazon Linux 2023 arm64 image, verified against Amazon ownership"
  type        = string
  default     = null
  validation {
    condition     = !var.enable_ssm_bridge || can(regex("^ami-[0-9a-f]{17}$", var.ssm_bridge_ami_id))
    error_message = "An immutable AMI ID is required when enabling the SSM bridge."
  }
}

variable "enable_outbox_service" {
  description = "Explicitly enable the persistent publisher; no ZIP build or deployment consumer"
  type        = bool
  default     = false
  validation {
    condition     = !var.enable_outbox_service || var.enable_ssm_bridge
    error_message = "The personal publisher currently requires the existing outbound gateway."
  }
}

variable "outbox_service_image" {
  description = "Reviewed personal sky-platform ECR image pinned by manifest digest"
  type        = string
  default     = null
  validation {
    condition     = !var.enable_outbox_service || can(regex("^${var.aws_account_id}\\.dkr\\.ecr\\.${var.region}\\.amazonaws\\.com/sky-platform@sha256:[0-9a-f]{64}$", var.outbox_service_image))
    error_message = "Pin a reviewed sky-platform image digest in the expected account and region."
  }
}

variable "enable_api_role" {
  description = "Create a restricted API runtime role without starting a hosted API service"
  type        = bool
  default     = false
}

variable "api_operator_principal_arn" {
  description = "Optional exact same-account IAM operator for local STS verification; leave null for ECS-only trust"
  type        = string
  default     = null
  validation {
    condition = var.api_operator_principal_arn == null || (
      var.enable_api_role && can(regex("^arn:aws:iam::${var.aws_account_id}:(user|role)/[A-Za-z0-9+=,.@_/-]+$", var.api_operator_principal_arn))
    )
    error_message = "Enable the API role and specify an exact same-account IAM user/role ARN, or leave operator trust null."
  }
}
