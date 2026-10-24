resource "aws_cognito_user_pool" "api" {
  count                    = var.enable_public_api ? 1 : 0
  name                     = "${var.name_prefix}-users"
  deletion_protection      = "ACTIVE"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  mfa_configuration        = "OPTIONAL"
  admin_create_user_config {
    allow_admin_create_user_only = true
  }
  software_token_mfa_configuration {
    enabled = true
  }
  password_policy {
    minimum_length                   = 14
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 1
  }
  account_recovery_setting {
    recovery_mechanism {
      name     = "admin_only"
      priority = 1
    }
  }
  lifecycle {
    prevent_destroy = true
  }
}
resource "aws_cognito_resource_server" "api" {
  count        = var.enable_public_api ? 1 : 0
  identifier   = "sky"
  name         = "Sky preparation API"
  user_pool_id = aws_cognito_user_pool.api[0].id
  scope {
    scope_name        = "deploy"
    scope_description = "Access Sky APIs subject to explicit organization membership and role"
  }
}
resource "aws_cognito_user_pool_domain" "api" {
  count        = var.enable_public_api ? 1 : 0
  domain       = "${var.name_prefix}-${var.aws_account_id}"
  user_pool_id = aws_cognito_user_pool.api[0].id
}
resource "aws_cognito_user_pool_client" "api" {
  count                                = var.enable_public_api ? 1 : 0
  name                                 = "${var.name_prefix}-browser"
  user_pool_id                         = aws_cognito_user_pool.api[0].id
  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "sky/deploy"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = ["https://${aws_cloudfront_distribution.api[0].domain_name}/auth/callback"]
  logout_urls                          = ["https://${aws_cloudfront_distribution.api[0].domain_name}/login"]
  explicit_auth_flows                  = ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors        = "ENABLED"
  enable_token_revocation              = true
  access_token_validity                = 15
  id_token_validity                    = 15
  refresh_token_validity               = 1
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
  depends_on = [aws_cognito_resource_server.api]
}
