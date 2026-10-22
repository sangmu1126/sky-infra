variable "region" {
  description = "state 버킷을 둘 AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "name_prefix" {
  description = "리소스 이름 접두어"
  type        = string
  default     = "sky"
}

variable "noncurrent_version_days" {
  description = "이전 state 버전을 보관할 일수"
  type        = number
  default     = 90
}
variable "aws_account_id" {
  description = "Optional account fence; personal bootstrap supplies the expected account explicitly"
  type        = string
  default     = null
  validation {
    condition     = var.aws_account_id == null ? true : can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit AWS account ID."
  }
}
