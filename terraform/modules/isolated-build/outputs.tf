output "profile" {
  value = {
    version         = 1, name = var.name,
    account_id      = data.aws_caller_identity.current.account_id, region = data.aws_region.current.region,
    vpc_id          = aws_vpc.sandbox.id, subnet_id = aws_subnet.sandbox.id, security_group_id = aws_security_group.sandbox.id,
    ssh_cidr        = var.ssh_cidr, max_lifetime_seconds = var.max_lifetime_seconds,
    scheduler_group = aws_scheduler_schedule_group.sandbox.name,
    scheduler_role  = aws_iam_role.scheduler.arn, reaper_arn = aws_lambda_function.reaper.arn,
    repository      = aws_ecr_repository.sandbox.name, review_queue_url = aws_sqs_queue.review.url,
    network_policy  = "no-egress", metadata_endpoint = "disabled", instance_profile = null
  }
}

output "publisher_role_arn" { value = aws_iam_role.publisher.arn }
