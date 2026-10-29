# Trusted controller parses source as data. It cannot alter the VPC/SG, obtain
# registry login tokens, read Secrets Manager or give an instance an IAM role.
resource "aws_iam_role" "controller" {
  name                 = "${var.name}-controller"
  max_session_duration = 3600
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Principal = { AWS = concat([var.publisher_principal_arn], [for role in data.aws_iam_role.github_builder : role.arn]) },
    Action = ["sts:AssumeRole", "sts:TagSession"],
    Condition = {
      StringLike                  = { "aws:RequestTag/sky:JobId" = "????????-????-????-????-????????????" },
      "ForAllValues:StringEquals" = { "aws:TagKeys" = ["sky:JobId"] }
    }
  }] })
  tags = local.tags
}
resource "aws_iam_role_policy" "controller" {
  role = aws_iam_role.controller.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ec2:DescribeInstances", "ec2:DescribeSecurityGroups", "ec2:DescribeSubnets", "ec2:DescribeVpcs", "ec2:DescribeImages"], Resource = "*",
    Condition = { StringEquals = { "aws:RequestedRegion" = data.aws_region.current.region } } },
    { Effect = "Allow", Action = ["ec2:GetConsoleOutput"], Resource = "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/*",
    Condition = { StringEquals = { "ec2:ResourceTag/app" = "sky", "ec2:ResourceTag/sky:SandboxProfile" = var.name, "ec2:ResourceTag/sky:JobId" = "$${aws:PrincipalTag/sky:JobId}" } } },
    { Effect = "Allow", Action = ["ec2:RunInstances"], Resource = [
      "arn:aws:ec2:${data.aws_region.current.region}::image/${var.trusted_ami_id}",
      "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:subnet/${aws_subnet.sandbox.id}",
      "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:security-group/${aws_security_group.sandbox.id}",
      "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:key-pair/${var.name}-$${aws:PrincipalTag/sky:JobId}"
    ] },
    { Effect = "Allow", Action = ["ec2:RunInstances"], Resource = [for kind in ["instance", "volume", "network-interface"] : "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:${kind}/*"],
    Condition = { StringEquals = { "aws:RequestTag/app" = "sky", "aws:RequestTag/sky:SandboxProfile" = var.name, "aws:RequestTag/sky:JobId" = "$${aws:PrincipalTag/sky:JobId}" } } },
    { Effect = "Deny", Action = ["ec2:RunInstances"], Resource = "arn:aws:ec2:*:*:instance/*", Condition = { StringNotEquals = { "ec2:InstanceType" = "t3.small" } } },
    { Effect = "Deny", Action = ["ec2:RunInstances"], Resource = "arn:aws:ec2:*:*:volume/*", Condition = { NumericGreaterThan = { "ec2:VolumeSize" = "30" } } },
    { Effect = "Deny", Action = ["ec2:RunInstances"], Resource = "arn:aws:ec2:*:*:volume/*", Condition = { Bool = { "ec2:Encrypted" = "false" } } },
    { Effect = "Allow", Action = ["ec2:CreateTags"], Resource = [for kind in ["instance", "volume", "network-interface", "key-pair"] : "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:${kind}/*"],
    Condition = { StringEquals = { "ec2:CreateAction" = ["RunInstances", "ImportKeyPair"], "aws:RequestTag/sky:JobId" = "$${aws:PrincipalTag/sky:JobId}" } } },
    { Effect = "Allow", Action = ["ec2:ImportKeyPair"], Resource = "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:key-pair/${var.name}-$${aws:PrincipalTag/sky:JobId}",
    Condition = { StringEquals = { "aws:RequestTag/sky:JobId" = "$${aws:PrincipalTag/sky:JobId}", "aws:RequestTag/app" = "sky", "aws:RequestTag/sky:SandboxProfile" = var.name } } },
    { Effect = "Allow", Action = ["ec2:DeleteKeyPair"], Resource = "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:key-pair/${var.name}-$${aws:PrincipalTag/sky:JobId}" },
    { Effect = "Allow", Action = ["ec2:TerminateInstances", "ec2:ModifyInstanceMetadataOptions"], Resource = "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/*",
    Condition = { StringEquals = { "ec2:ResourceTag/app" = "sky", "ec2:ResourceTag/sky:SandboxProfile" = var.name, "ec2:ResourceTag/sky:JobId" = "$${aws:PrincipalTag/sky:JobId}" } } },
    { Effect = "Allow", Action = ["scheduler:CreateSchedule", "scheduler:GetSchedule"], Resource = "arn:aws:scheduler:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:schedule/${aws_scheduler_schedule_group.sandbox.name}/job-$${aws:PrincipalTag/sky:JobId}" },
    { Effect = "Allow", Action = ["iam:PassRole"], Resource = aws_iam_role.scheduler.arn, Condition = { StringEquals = { "iam:PassedToService" = "scheduler.amazonaws.com" } } },
    { Effect = "Deny", Action = ["secretsmanager:*", "ssm:GetParameter*", "kms:Decrypt", "ecr:GetAuthorizationToken", "ec2:AssociateIamInstanceProfile", "ec2:ReplaceIamInstanceProfileAssociation"], Resource = "*" }
  ] })
}
output "controller_role_arn" { value = aws_iam_role.controller.arn }
