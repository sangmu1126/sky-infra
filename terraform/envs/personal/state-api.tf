# The value is provisioned over TLS by an operator, never written into Terraform state.
resource "aws_secretsmanager_secret" "state_api" {
  name                    = "${var.name_prefix}/state-api"
  description             = "Sky API-only state database identity; not the RDS administrator"
  recovery_window_in_days = 30
  lifecycle {
    prevent_destroy = true
  }
}
