# Outbound-only Session Manager bridge. Never runs user apps or stores DB credentials.
data "aws_ami" "ssm_bridge" {
  count  = var.enable_ssm_bridge ? 1 : 0
  owners = ["amazon"]
  filter {
    name   = "image-id"
    values = [var.ssm_bridge_ami_id]
  }
  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

resource "aws_internet_gateway" "bridge" {
  count  = var.enable_ssm_bridge ? 1 : 0
  vpc_id = aws_vpc.this.id
}

resource "aws_subnet" "bridge" {
  count                   = var.enable_ssm_bridge ? 1 : 0
  vpc_id                  = aws_vpc.this.id
  availability_zone       = "ap-northeast-2a"
  cidr_block              = "10.42.0.0/24"
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name_prefix}-ssm", "sky:tier" = "management" }
}

resource "aws_route_table" "bridge" {
  count  = var.enable_ssm_bridge ? 1 : 0
  vpc_id = aws_vpc.this.id
}

resource "aws_route" "bridge_outbound" {
  count                  = var.enable_ssm_bridge ? 1 : 0
  route_table_id         = aws_route_table.bridge[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.bridge[0].id
}

resource "aws_route_table_association" "bridge" {
  count          = var.enable_ssm_bridge ? 1 : 0
  subnet_id      = aws_subnet.bridge[0].id
  route_table_id = aws_route_table.bridge[0].id
}

resource "aws_security_group" "bridge" {
  count       = var.enable_ssm_bridge ? 1 : 0
  name        = "${var.name_prefix}-ssm"
  description = "No inbound ports; SSM outbound HTTPS and state PostgreSQL only"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_egress_rule" "bridge_https" {
  count             = var.enable_ssm_bridge ? 1 : 0
  security_group_id = aws_security_group.bridge[0].id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "bridge_database" {
  count                        = var.enable_ssm_bridge ? 1 : 0
  security_group_id            = aws_security_group.bridge[0].id
  referenced_security_group_id = aws_security_group.database.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "database_from_bridge" {
  count                        = var.enable_ssm_bridge ? 1 : 0
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.bridge[0].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_iam_role" "bridge" {
  count = var.enable_ssm_bridge ? 1 : 0
  name  = "${var.name_prefix}-ssm"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "bridge" {
  count = var.enable_ssm_bridge ? 1 : 0
  role  = aws_iam_role.bridge[0].id
  name  = "SessionChannelsOnly"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ssm:UpdateInstanceInformation"], Resource = "*" },
      { Effect = "Allow", Action = ["ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel", "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"], Resource = "*" }
    ]
  })
}

resource "aws_iam_instance_profile" "bridge" {
  count = var.enable_ssm_bridge ? 1 : 0
  name  = "${var.name_prefix}-ssm"
  role  = aws_iam_role.bridge[0].name
}

resource "aws_instance" "ssm_bridge" {
  count                       = var.enable_ssm_bridge ? 1 : 0
  ami                         = data.aws_ami.ssm_bridge[0].id
  instance_type               = "t4g.nano"
  subnet_id                   = aws_subnet.bridge[0].id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.bridge[0].id]
  iam_instance_profile        = aws_iam_instance_profile.bridge[0].name
  monitoring                  = false
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    encrypted             = true
    volume_type           = "gp3"
    volume_size           = 8
    delete_on_termination = true
  }
  tags       = { Name = "${var.name_prefix}-ssm", "sky:purpose" = "private-management-only" }
  depends_on = [aws_route.bridge_outbound, aws_iam_role_policy.bridge]
}
