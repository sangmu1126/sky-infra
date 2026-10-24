mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com", client_id_list = ["sts.amazonaws.com"] }
  }
  mock_data "aws_ecr_repository" {
    defaults = { arn = "arn:aws:ecr:ap-northeast-2:123456789012:repository/sky-managed" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::personal-artifacts-test" }
  }
}
variables {
  aws_account_id             = "123456789012"
  enable_public_api          = false
  public_api_image           = null
  api_memberships            = []
  enable_api_role            = false
  api_operator_principal_arn = null
  enable_ssm_bridge          = false
  enable_outbox_service      = false
  outbox_service_image       = null
  enable_builder_role        = false
  builder_oidc_subject       = null
}
run "builder_disabled_by_default" {
  command = plan
  assert {
    condition     = length(aws_iam_role.builder) == 0 && length(aws_iam_role_policy.builder) == 0 && output.builder_role_arn == null
    error_message = "Builder permissions must require explicit opt-in."
  }
}
run "builder_has_exact_trust_and_bounded_artifacts" {
  command = apply
  variables {
    enable_builder_role  = true
    builder_oidc_subject = "repo:sangmu1126@12345/sky-builder@67890:ref:refs/heads/main"
  }
  assert {
    condition = jsondecode(aws_iam_role.builder[0].assume_role_policy).Statement[0].Condition.StringEquals == {
      "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
      "token.actions.githubusercontent.com:sub" = var.builder_oidc_subject
    } && aws_iam_role.builder[0].max_session_duration == 3600
    error_message = "Only the exact immutable personal builder/main and STS audience may assume the role."
  }
  assert {
    condition = toset(flatten([for s in jsondecode(aws_iam_role_policy.builder[0].policy).Statement : s.Action])) == toset([
      "ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages", "s3:GetObject", "s3:PutObject"
    ])
    error_message = "Builder must have no deployment, IAM, queue, database or Secret permissions."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.builder[0].policy).Statement[1].Resource == data.aws_ecr_repository.builder[0].arn && jsondecode(aws_iam_role_policy.builder[0].policy).Statement[2].Resource == "${module.artifacts.bucket_arn}/sources/personal/*" && jsondecode(aws_iam_role_policy.builder[0].policy).Statement[3].Resource == "${module.artifacts.bucket_arn}/builds/*" && jsondecode(aws_iam_role_policy.builder[0].policy).Statement[3].Condition.StringEquals["s3:x-amz-server-side-encryption"] == "AES256"
    error_message = "Image writes must use app ECR only, source reads the personal workspace and result writes encrypted build records."
  }
}
run "builder_rejects_mutable_subject" {
  command = plan
  variables {
    enable_builder_role  = true
    builder_oidc_subject = "repo:sangmu1126/sky-builder:ref:refs/heads/main"
  }
  expect_failures = [var.builder_oidc_subject]
}
run "builder_rejects_other_branch" {
  command = plan
  variables {
    enable_builder_role  = true
    builder_oidc_subject = "repo:sangmu1126@12345/sky-builder@67890:ref:refs/heads/feature"
  }
  expect_failures = [var.builder_oidc_subject]
}
run "builder_rejects_missing_subject" {
  command = plan
  variables {
    enable_builder_role  = true
    builder_oidc_subject = null
  }
  expect_failures = [var.builder_oidc_subject]
}
