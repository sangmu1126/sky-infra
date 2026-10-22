# Provision the credential value explicitly over TLS; never put it into Terraform state.
resource "aws_secretsmanager_secret" "state_outbox" {
  name                    = "${var.name_prefix}/state-outbox"
  description             = "Sky outbox publisher DB identity; not API, deployment consumer or administrator"
  recovery_window_in_days = 30
  lifecycle {
    prevent_destroy = true
  }
}

output "outbox_environment" {
  description = "Publisher-only connection references; no consumer/deployment permissions"
  value = merge(local.state_environment, {
    SKY_DATABASE_SECRET_ARN = aws_secretsmanager_secret.state_outbox.arn
  })
}
