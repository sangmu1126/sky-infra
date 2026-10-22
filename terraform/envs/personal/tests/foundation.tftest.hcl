mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { region = "ap-northeast-2" }
  }
}

variables {
  aws_account_id = "123456789012"
}

run "private_foundation" {
  command = apply

  assert {
    condition     = alltrue([for subnet in aws_subnet.data : !subnet.map_public_ip_on_launch])
    error_message = "Data subnets must not assign public IPs."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.database_from_tasks.referenced_security_group_id == aws_security_group.tasks.id && aws_vpc_security_group_ingress_rule.database_from_tasks.from_port == 5432 && aws_vpc_security_group_ingress_rule.database_from_tasks.to_port == 5432 && aws_vpc_security_group_ingress_rule.database_from_tasks.cidr_ipv4 == null
    error_message = "State DB access must be scoped to the task security group on PostgreSQL only."
  }

  assert {
    condition     = output.runtime_environment.SKY_STATE_WORKSPACE == "personal" && output.runtime_environment.SKY_AWS_ACCOUNT_ID == var.aws_account_id
    error_message = "Runtime references must remain scoped to the personal workspace/account."
  }
}

run "state_database_protection" {
  command = plan
  module {
    source = "../../modules/state-db"
  }
  variables {
    name_prefix       = "sky-personal"
    data_subnet_ids   = ["subnet-11111111", "subnet-22222222"]
    security_group_id = "sg-11111111"
    instance_class    = "db.t4g.micro"
    multi_az          = false
  }
  assert {
    condition     = !aws_db_instance.this.publicly_accessible && aws_db_instance.this.storage_encrypted && aws_db_instance.this.deletion_protection && aws_db_instance.this.manage_master_user_password && !aws_db_instance.this.skip_final_snapshot
    error_message = "State DB must be private/encrypted/protected and use an RDS-managed credential."
  }
  assert {
    condition     = anytrue([for parameter in aws_db_parameter_group.this.parameter : parameter.name == "rds.force_ssl" && parameter.value == "1"])
    error_message = "State DB must reject non-TLS connections."
  }
}
