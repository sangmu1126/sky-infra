# Trusted GitHub controller only. User projects execute in different no-egress VMs.
# No instance role, workload source, GitHub token or signing key in Terraform/user-data.
variable "enable_controller_host" {
  type    = bool
  default = false
}
variable "controller_bootstrap_complete" {
  type    = bool
  default = false
}
variable "controller_operator_ssh_cidr" {
  type    = string
  default = null
}
variable "controller_ami_id" {
  type    = string
  default = null
}
variable "controller_ssh_public_key" {
  type    = string
  default = null
  validation {
    condition     = !var.enable_controller_host || can(regex("^ssh-ed25519 [A-Za-z0-9+/=]+", var.controller_ssh_public_key))
    error_message = "Explicit operator public SSH key required, never a private key."
  }
}
data "aws_ami" "controller" {
  count  = var.enable_controller_host ? 1 : 0
  owners = ["099720109477"] # Canonical
  filter {
    name   = "image-id"
    values = [var.controller_ami_id]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}
resource "aws_vpc" "controller" {
  count                = var.enable_controller_host ? 1 : 0
  cidr_block           = "10.243.0.0/24"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "sky-security-controller", "sky:Purpose" = "trusted-controller" }
}
resource "aws_subnet" "controller" {
  count             = var.enable_controller_host ? 1 : 0
  vpc_id            = aws_vpc.controller[0].id
  cidr_block        = "10.243.0.0/28"
  availability_zone = "${var.aws_region}a"
}
resource "aws_internet_gateway" "controller" {
  count  = var.enable_controller_host ? 1 : 0
  vpc_id = aws_vpc.controller[0].id
}
resource "aws_route_table" "controller" {
  count  = var.enable_controller_host ? 1 : 0
  vpc_id = aws_vpc.controller[0].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.controller[0].id
  }
}
resource "aws_route_table_association" "controller" {
  count          = var.enable_controller_host ? 1 : 0
  subnet_id      = aws_subnet.controller[0].id
  route_table_id = aws_route_table.controller[0].id
}
resource "aws_security_group" "controller" {
  count  = var.enable_controller_host ? 1 : 0
  name   = "sky-security-controller"
  vpc_id = aws_vpc.controller[0].id
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [coalesce(var.controller_operator_ssh_cidr, var.operator_ssh_cidr)]
  }
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "SSH to receipt-verified disposable build guests; controller executes no workload"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { "sky:Purpose" = "trusted-controller" }
}
resource "aws_key_pair" "controller" {
  count      = var.enable_controller_host ? 1 : 0
  key_name   = "sky-security-controller"
  public_key = var.controller_ssh_public_key
}
resource "aws_instance" "controller" {
  count                       = var.enable_controller_host ? 1 : 0
  ami                         = data.aws_ami.controller[0].id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.controller[0].id
  vpc_security_group_ids      = [aws_security_group.controller[0].id]
  iam_instance_profile        = "" # Explicitly no AWS credentials on the controller host.
  key_name                    = aws_key_pair.controller[0].key_name
  associate_public_ip_address = false
  user_data_replace_on_change = true
  metadata_options {
    http_endpoint               = var.controller_bootstrap_complete ? "disabled" : "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }
  root_block_device {
    encrypted             = true
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }
  lifecycle {
    # EC2 reports true after an Elastic IP is attached; do not replace the host.
    ignore_changes = [associate_public_ip_address]
  }
  credit_specification { cpu_credits = "standard" }
  user_data  = <<-BOOT
    #!/bin/bash
    set -eu
    # No API keys or instance role exist. Publish the host key through AWS console.
    echo "SKY_CONTROLLER_HOST_KEY=$(cat /etc/ssh/ssh_host_ed25519_key.pub)" > /dev/console
    sed -i 's|http://|https://|g' /etc/apt/sources.list.d/ubuntu.sources
    apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl git unzip jq python3-venv libicu74 libkrb5-3 libssl3t64 liblttng-ust1t64
    useradd --create-home --shell /bin/bash sky-controller
    install -d -o sky-controller -g sky-controller -m 700 /opt/sky-controller
    echo SKY_CONTROLLER_BOOTSTRAP_COMPLETE > /dev/console
  BOOT
  tags       = { Name = "sky-security-controller", "sky:Purpose" = "trusted-controller", "sky:NoWorkloadExecution" = "true" }
  depends_on = [aws_route_table_association.controller]
}
resource "aws_eip" "controller" {
  count      = var.enable_controller_host ? 1 : 0
  domain     = "vpc"
  instance   = aws_instance.controller[0].id
  tags       = { Name = "sky-security-controller-static-egress" }
  depends_on = [aws_internet_gateway.controller]
}
output "controller_host" {
  value = var.enable_controller_host ? {
    instance_id = aws_instance.controller[0].id
    public_ip   = aws_eip.controller[0].public_ip
    purpose     = "trusted controller only; not a workload sandbox"
  } : null
}
