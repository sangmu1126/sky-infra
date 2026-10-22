output "runtime_environment" {
  description = "Non-secret connection references; API/worker/auth are not deployed yet"
  value = {
    SKY_AWS_ACCOUNT_ID      = var.aws_account_id
    SKY_AWS_REGION          = var.region
    SKY_STATE_WORKSPACE     = "personal"
    SKY_DATABASE_HOST       = module.state_db.address
    SKY_DATABASE_PORT       = tostring(module.state_db.port)
    SKY_DATABASE_NAME       = module.state_db.database_name
    SKY_DATABASE_SECRET_ARN = module.state_db.master_secret_arn
    SKY_ARTIFACTS_BUCKET    = module.artifacts.bucket_name
    SKY_JOB_QUEUE_URL       = module.queue.queue_url
  }
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "task_security_group_id" {
  value = aws_security_group.tasks.id
}

output "state_database_id" {
  value = module.state_db.identifier
}
output "ssm_database_forwarding" {
  value = var.enable_ssm_bridge ? {
    instance_id   = aws_instance.ssm_bridge[0].id
    document_name = "AWS-StartPortForwardingSessionToRemoteHost"
    database_host = module.state_db.address
    database_port = module.state_db.port
  } : null
}
