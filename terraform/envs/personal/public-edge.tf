# Domain-free HTTPS entry. No public ALB, origin credentials, or API response caching.
resource "aws_subnet" "api_edge" {
  for_each                = var.enable_public_api ? { "ap-northeast-2a" = "10.42.10.0/24", "ap-northeast-2c" = "10.42.11.0/24" } : {}
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name_prefix}-edge-${each.key}", "sky:tier" = "private-edge" }
}
resource "aws_route_table_association" "api_edge" {
  for_each       = aws_subnet.api_edge
  subnet_id      = each.value.id
  route_table_id = aws_route_table.data.id # Local-only; no route through the IGW.
}
resource "aws_security_group" "api_alb" {
  count       = var.enable_public_api ? 1 : 0
  name        = "${var.name_prefix}-private-api-alb"
  description = "CloudFront VPC-origin service SG only; no internet ingress"
  vpc_id      = aws_vpc.this.id
}
resource "aws_lb" "api" {
  count              = var.enable_public_api ? 1 : 0
  name               = "${substr(var.name_prefix, 0, 27)}-api"
  internal           = true
  load_balancer_type = "application"
  subnets            = [for subnet in aws_subnet.api_edge : subnet.id]
  security_groups    = [aws_security_group.api_alb[0].id]
  idle_timeout       = 120
  # Never enable query-string access logs for OAuth callbacks without redaction.
  depends_on = [aws_route_table_association.api_edge]
}
resource "aws_lb_target_group" "api" {
  count                = var.enable_public_api ? 1 : 0
  name                 = "${substr(var.name_prefix, 0, 27)}-api"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.this.id
  deregistration_delay = 60
  health_check {
    path                = "/ready"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}
resource "aws_lb_listener" "api" {
  count             = var.enable_public_api ? 1 : 0
  load_balancer_arn = aws_lb.api[0].arn
  port              = 80
  protocol          = "HTTP" # Private CloudFront VPC connection, never a public listener.
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api[0].arn
  }
}
resource "aws_cloudfront_vpc_origin" "api" {
  count = var.enable_public_api ? 1 : 0
  vpc_origin_endpoint_config {
    name                   = "${var.name_prefix}-api"
    arn                    = aws_lb.api[0].arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"
    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
  depends_on = [aws_lb_listener.api, aws_internet_gateway.bridge]
}
# AWS creates this SG with the VPC origin; do not create or mutate it ourselves.
data "aws_security_group" "cloudfront_api" {
  count  = var.enable_public_api ? 1 : 0
  vpc_id = aws_vpc.this.id
  filter {
    name   = "group-name"
    values = ["CloudFront-VPCOrigins-Service-SG*"]
  }
  depends_on = [aws_cloudfront_vpc_origin.api]
}
resource "aws_vpc_security_group_ingress_rule" "api_from_cloudfront" {
  count                        = var.enable_public_api ? 1 : 0
  security_group_id            = aws_security_group.api_alb[0].id
  referenced_security_group_id = data.aws_security_group.cloudfront_api[0].id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}
data "aws_cloudfront_cache_policy" "api_disabled" {
  count = var.enable_public_api ? 1 : 0
  name  = "Managed-CachingDisabled"
}
resource "aws_cloudfront_origin_request_policy" "api" {
  count = var.enable_public_api ? 1 : 0
  name  = "${var.name_prefix}-api-request"
  cookies_config {
    cookie_behavior = "none"
  }
  headers_config {
    header_behavior = "allExcept"
    headers {
      items = ["Host"] # Preserve Authorization/Origin; Host is the internal ALB name.
    }
  }
  query_strings_config {
    query_string_behavior = "all"
  }
}
resource "aws_cloudfront_distribution" "api" {
  count           = var.enable_public_api ? 1 : 0
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${var.name_prefix} authenticated API"
  price_class     = "PriceClass_200"
  origin {
    domain_name = aws_lb.api[0].dns_name
    origin_id   = "private-api"
    vpc_origin_config {
      vpc_origin_id = aws_cloudfront_vpc_origin.api[0].id
    }
  }
  default_cache_behavior {
    target_origin_id         = "private-api"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "POST", "PUT", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.api_disabled[0].id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.api[0].id
    compress                 = true
  }
  custom_error_response {
    error_code            = 403
    error_caching_min_ttl = 0
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  viewer_certificate {
    cloudfront_default_certificate = true
  }
  depends_on = [aws_vpc_security_group_ingress_rule.api_from_cloudfront]
}
