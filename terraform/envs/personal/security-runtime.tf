# Non-secret operator policy; never derive limits from an uploaded project.
variable "security_effect_budget_json" {
  description = "Optional expiring operator budget. The application validates the full contract at startup; no inferred prices or credentials."
  type        = string
  default     = null
  validation {
    condition = var.security_effect_budget_json == null || try(
      jsondecode(var.security_effect_budget_json).version == 2 &&
      length(jsondecode(var.security_effect_budget_json).source) > 0 &&
      can(timeadd(jsondecode(var.security_effect_budget_json).expires_at, "0s")) &&
      toset(keys(jsondecode(var.security_effect_budget_json))) == toset(["version", "expires_at", "source", "limits", "effects"]),
      false
    )
    error_message = "Supply an exact version-2 operator policy with explicit expiry, source, limits and effects; never a secret."
  }
}

locals {
  security_runtime_environment = var.security_effect_budget_json == null ? {} : {
    SKY_REQUIRE_EFFECT_BUDGETS = "true"
    SKY_EFFECT_BUDGET_JSON     = var.security_effect_budget_json
  }
}
