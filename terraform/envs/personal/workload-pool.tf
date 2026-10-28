# Application data is never placed in module.state_db. Registration is explicit;
# creating this foundation does not start an allocation/build queue consumer.
module "workload_pool" {
  count                       = var.enable_shared_workload_pool ? 1 : 0
  source                      = "../../modules/workload-pool"
  name_prefix                 = var.name_prefix
  pool_id                     = "personal"
  vpc_id                      = aws_vpc.this.id
  data_subnet_ids             = [for subnet in aws_subnet.data : subnet.id]
  allocator_security_group_id = aws_security_group.bridge[0].id
  instance_class              = var.shared_workload_instance_class
  engine_version              = var.postgres_version
  connection_budget           = var.shared_workload_connection_budget
  multi_az                    = false
}

# Explicit operator initialization over SSM. The bridge has no DB secrets IAM
# permission, and neither the API nor its SG receives access to this pool.
resource "aws_vpc_security_group_egress_rule" "bridge_workload_database" {
  count                        = var.enable_shared_workload_pool ? 1 : 0
  security_group_id            = aws_security_group.bridge[0].id
  referenced_security_group_id = module.workload_pool[0].registration.settings.database_security_group
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

output "shared_workload_pool_registration" {
  description = "Credential-free allocation registration. Initialize explicitly; hosted consumers remain unchanged."
  value       = var.enable_shared_workload_pool ? module.workload_pool[0].registration : null
}

output "shared_workload_runtime_security_group_id" {
  value = var.enable_shared_workload_pool ? module.workload_pool[0].runtime_security_group_id : null
}

variable "enable_shared_workload_pool" {
  type        = bool
  default     = false
  description = "Create a persistent, private application RDS pool separate from Sky state."
  validation {
    condition     = !var.enable_shared_workload_pool || var.enable_ssm_bridge
    error_message = "The personal workload pool requires the explicit operator SSM bridge."
  }
}

variable "shared_workload_instance_class" {
  type    = string
  default = "db.t4g.micro"
  validation {
    condition     = contains(["db.t4g.micro", "db.t4g.small"], var.shared_workload_instance_class)
    error_message = "Use an explicitly bounded personal workload instance class."
  }
}

variable "shared_workload_connection_budget" {
  type    = number
  default = 30
  validation {
    condition     = var.shared_workload_connection_budget == floor(var.shared_workload_connection_budget) && var.shared_workload_connection_budget >= 1 && var.shared_workload_connection_budget <= 30
    error_message = "Personal app connection reservations must be an integer between 1 and 30."
  }
}
