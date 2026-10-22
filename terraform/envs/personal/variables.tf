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
