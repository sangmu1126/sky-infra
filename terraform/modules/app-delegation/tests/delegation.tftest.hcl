mock_provider "aws" {
  mock_resource "aws_iam_policy" { defaults = { arn = "arn:aws:iam::123456789012:policy/sky-app-test-boundary" } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::123456789012:role/sky-app-test", unique_id = "AROAAAAAAAAAAAAAAAAAA" } }
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
}
variables {
  secret_kms_key_arn   = "arn:aws:kms:ap-northeast-2:123456789012:key/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  name                 = "sky-app-test"
  account_id           = "123456789012"
  region               = "ap-northeast-2"
  organization_id      = "personal"
  application_id       = "app-a"
  external_id          = "operator-external-binding-1234567890"
  source_principal_arn = "arn:aws:iam::123456789012:role/sky-control"
  owned_secret_arns    = ["arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:app-a-AbCdEf"]
}
run "boundary_is_mandatory_and_foreign_secrets_explicitly_denied" {
  command = apply
  assert {
    condition     = aws_iam_role.application.permissions_boundary == aws_iam_policy.boundary.arn && length([for statement in jsondecode(aws_iam_policy.boundary.policy).Statement : statement if statement.Effect == "Deny" && try(toset(statement.NotResource), toset([])) == toset(var.owned_secret_arns)]) == 1
    error_message = "App boundary must be attached and explicitly deny reads outside its exact Secret set."
  }
  assert {
    condition     = jsondecode(aws_iam_role.application.assume_role_policy).Statement[0].Principal.AWS == var.source_principal_arn && jsondecode(aws_iam_role.application.assume_role_policy).Statement[0].Condition.StringEquals["aws:RequestTag/sky:ApplicationId"] == var.application_id
    error_message = "Trusted source and requested app scope must both match, not user-supplied tag assertions alone."
  }
}
run "foreign_secret_cannot_be_registered" {
  command = plan
  variables { owned_secret_arns = ["arn:aws:secretsmanager:ap-northeast-2:999999999999:secret:app-a-AbCdEf"] }
  expect_failures = [var.owned_secret_arns]
}
run "wildcard_secret_cannot_be_registered" {
  command = plan
  variables { owned_secret_arns = ["arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:*"] }
  expect_failures = [var.owned_secret_arns]
}
