# Personal hosted foundation. No public ingress, NAT, API or worker is enabled here.
terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {}
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.aws_account_id]
  default_tags {
    tags = {
      "sky:managed-by"  = "sky-infra"
      "sky:environment" = "personal"
      "sky:purpose"     = "hosted-foundation"
    }
  }
}

resource "aws_vpc" "this" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.name_prefix }
}

resource "aws_subnet" "data" {
  for_each = {
    "ap-northeast-2a" = "10.42.20.0/24"
    "ap-northeast-2c" = "10.42.21.0/24"
  }
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name_prefix}-data-${each.key}", "sky:tier" = "data" }
}

resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-data-local-only" }
}

resource "aws_route_table_association" "data" {
  for_each       = aws_subnet.data
  subnet_id      = each.value.id
  route_table_id = aws_route_table.data.id
}

resource "aws_security_group" "tasks" {
  name        = "${var.name_prefix}-tasks"
  description = "Reserved for Sky API and workers; no incoming connections"
  vpc_id      = aws_vpc.this.id
}

resource "aws_security_group" "database" {
  name        = "${var.name_prefix}-state"
  description = "Sky control-plane state; not an application workload database"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_ingress_rule" "database_from_tasks" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "tasks_to_database" {
  security_group_id            = aws_security_group.tasks.id
  referenced_security_group_id = aws_security_group.database.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

module "state_db" {
  source                    = "../../modules/state-db"
  name_prefix               = var.name_prefix
  data_subnet_ids           = [for subnet in aws_subnet.data : subnet.id]
  security_group_id         = aws_security_group.database.id
  engine_version            = var.postgres_version
  instance_class            = var.state_db_instance_class
  multi_az                  = var.state_db_multi_az
  max_allocated_storage_gib = 40
  backup_retention_days     = 7
}

module "artifacts" {
  source      = "../../modules/artifacts"
  name_prefix = var.name_prefix
}

module "queue" {
  source      = "../../modules/queue"
  name_prefix = var.name_prefix
}
