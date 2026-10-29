# ---------------------------------------------------------------------------
# 워커 태스크 역할: 큐에서 작업을 받아 사용자 앱(배포 서버)을 만들고 지운다
# 이름이 sky-core-*, sky-db-* 와 겹치지 않게 해 자기 역할을 고칠 수 없게 한다.
#
# A안과 다른 점
#   1. 이미지 빌드·push를 하지 않는다 (GitHub Actions 빌드 워크플로가 한다). ECR은 조회·정리만.
#   2. 사용자 앱 역할(sky-core-*, sky-db-*)은 권한 경계를 달아야만 만들고 고칠 수 있다.
#      A안의 남은 위험(임의 인라인 정책 → PassRole → RunTask로 권한 상승)을 경계로 막는다.
# ---------------------------------------------------------------------------

locals {
  managed_role_arns = [
    "arn:${local.partition}:iam::${local.account}:role/sky-core-*",
    "arn:${local.partition}:iam::${local.account}:role/sky-db-*",
  ]
  managed_stack_arns = [
    "arn:${local.partition}:cloudformation:${local.region}:${local.account}:stack/sky-core/*",
    "arn:${local.partition}:cloudformation:${local.region}:${local.account}:stack/sky-db-*/*",
    "arn:${local.partition}:cloudformation:${local.region}:${local.account}:stack/sky-network-*/*",
  ]
  managed_repository_arn = "arn:${local.partition}:ecr:${local.region}:${local.account}:repository/sky-managed"
  default_cluster_arn    = "arn:${local.partition}:ecs:${local.region}:${local.account}:cluster/default"

  # sky-platform CloudFormation 템플릿이 역할에 붙이는 관리형 정책. 이 외의 정책은 붙일 수 없다.
  attachable_policy_arns = [
    "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
    "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSInfrastructureRoleforExpressGatewayServices",
  ]
}

# ---------------------------------------------------------------------------
# 사용자 앱 역할 권한 경계
# sky-core-*, sky-db-* 역할이 실제로 쓸 수 있는 권한의 상한. 역할에 무엇을 붙여도 이 밖으로 나가지 못한다.
# 내용 = 템플릿이 붙이는 관리형 정책 두 개를 조건까지 그대로 옮긴 것 + sky-db 인라인 정책(rds! 비밀 읽기).
# 조건(AmazonECSManaged 태그)을 빼면 장악된 역할이 Sky 자체 ALB·보안 그룹을 고칠 수 있으므로 반드시 함께 옮긴다.
# 대조 기준 (2026-10-10 조회):
#   AmazonECSTaskExecutionRolePolicy                      v1
#   AmazonECSInfrastructureRoleforExpressGatewayServices  v6
# AWS가 정책을 갱신하면 같은 명령(docs/design-b.md 5.3)으로 다시 받아 이 블록을 맞춘다.
# ---------------------------------------------------------------------------

# 관리형 정책 문서는 6144자 한도 안에 들어가야 한다. 그래서 자원 ARN의 리전·계정은 원본처럼 *:*로 둔다.
# 범위는 AmazonECSManaged 태그 조건이 정하고, 경계는 이 계정의 역할에만 붙으므로 넓어지지 않는다.
locals {
  arn_prefix = {
    elb   = "arn:${local.partition}:elasticloadbalancing:*:*"
    ec2   = "arn:${local.partition}:ec2:*:*"
    acm   = "arn:${local.partition}:acm:*:*"
    aas   = "arn:${local.partition}:application-autoscaling:*:*"
    cw    = "arn:${local.partition}:cloudwatch:*:*"
    logs  = "arn:${local.partition}:logs:*:*"
    roles = "arn:${local.partition}:iam::${local.account}:role/aws-service-role"
  }
  elb_resources = [
    "${local.arn_prefix.elb}:loadbalancer/app/*/*",
    "${local.arn_prefix.elb}:listener/app/*/*/*",
    "${local.arn_prefix.elb}:listener-rule/app/*/*/*/*",
    "${local.arn_prefix.elb}:targetgroup/*/*",
  ]
}

data "aws_iam_policy_document" "deployed_app_boundary" {
  # --- AmazonECSTaskExecutionRolePolicy v1 ---
  statement {
    sid = "TaskExecution"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["*"]
  }

  # --- aws-postgres.json DatabaseExecutionRole 인라인 정책 ---
  statement {
    sid       = "ReadRdsManagedSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:${local.partition}:secretsmanager:${local.region}:${local.account}:secret:rds!*"]
  }

  # --- AmazonECSInfrastructureRoleforExpressGatewayServices v6 ---
  statement {
    sid       = "ServiceLinkedRoleCreateOperations"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["${local.arn_prefix.roles}/*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["ecs.application-autoscaling.amazonaws.com", "elasticloadbalancing.amazonaws.com"]
    }
  }
  statement {
    sid = "ELBOperations"
    actions = [
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:CreateTargetGroup",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:ModifyRule",
      "elasticloadbalancing:AddListenerCertificates",
      "elasticloadbalancing:RemoveListenerCertificates",
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:DeregisterTargets",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:DeleteRule",
      "elasticloadbalancing:DeleteListener",
    ]
    resources = local.elb_resources
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/AmazonECSManaged"
      values   = ["true"]
    }
  }
  statement {
    sid       = "TagOnCreateELBResources"
    actions   = ["elasticloadbalancing:AddTags"]
    resources = local.elb_resources
    condition {
      test     = "StringEquals"
      variable = "elasticloadbalancing:CreateAction"
      values   = ["CreateLoadBalancer", "CreateListener", "CreateRule", "CreateTargetGroup"]
    }
  }
  statement {
    sid       = "BlanketAllowCreateSecurityGroupsInVPCs"
    actions   = ["ec2:CreateSecurityGroup"]
    resources = ["${local.arn_prefix.ec2}:vpc/*"]
  }
  statement {
    sid     = "CreateSecurityGroupResourcesWithTags"
    actions = ["ec2:CreateSecurityGroup", "ec2:AuthorizeSecurityGroupEgress", "ec2:AuthorizeSecurityGroupIngress"]
    resources = [
      "${local.arn_prefix.ec2}:security-group/*",
      "${local.arn_prefix.ec2}:security-group-rule/*",
      "${local.arn_prefix.ec2}:vpc/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/AmazonECSManaged"
      values   = ["true"]
    }
  }
  statement {
    sid = "ModifySecurityGroupOperations"
    actions = [
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:DeleteSecurityGroup",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
    ]
    resources = ["${local.arn_prefix.ec2}:security-group/*", "${local.arn_prefix.ec2}:vpc/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/AmazonECSManaged"
      values   = ["true"]
    }
  }
  statement {
    sid       = "TagOnCreateEC2Resources"
    actions   = ["ec2:CreateTags"]
    resources = ["${local.arn_prefix.ec2}:security-group/*", "${local.arn_prefix.ec2}:security-group-rule/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateSecurityGroup", "AuthorizeSecurityGroupIngress", "AuthorizeSecurityGroupEgress"]
    }
  }
  statement {
    sid       = "CertificateOperations"
    actions   = ["acm:RequestCertificate", "acm:AddTagsToCertificate", "acm:DeleteCertificate", "acm:DescribeCertificate"]
    resources = ["${local.arn_prefix.acm}:certificate/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/AmazonECSManaged"
      values   = ["true"]
    }
  }
  statement {
    sid = "ApplicationAutoscalingCreateOperations"
    actions = [
      "application-autoscaling:RegisterScalableTarget",
      "application-autoscaling:TagResource",
      "application-autoscaling:DeregisterScalableTarget",
    ]
    resources = ["${local.arn_prefix.aas}:scalable-target/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/AmazonECSManaged"
      values   = ["true"]
    }
  }
  statement {
    sid       = "ApplicationAutoscalingPolicyOperations"
    actions   = ["application-autoscaling:PutScalingPolicy", "application-autoscaling:DeleteScalingPolicy"]
    resources = ["${local.arn_prefix.aas}:scalable-target/*"]
    condition {
      test     = "StringEquals"
      variable = "application-autoscaling:service-namespace"
      values   = ["ecs"]
    }
  }
  statement {
    sid = "ApplicationAutoscalingReadOperations"
    actions = [
      "application-autoscaling:DescribeScalableTargets",
      "application-autoscaling:DescribeScalingPolicies",
      "application-autoscaling:DescribeScalingActivities",
    ]
    resources = ["${local.arn_prefix.aas}:scalable-target/*"]
  }
  statement {
    sid       = "CloudWatchAlarmCreateOperations"
    actions   = ["cloudwatch:PutMetricAlarm", "cloudwatch:TagResource"]
    resources = ["${local.arn_prefix.cw}:alarm:*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/AmazonECSManaged"
      values   = ["true"]
    }
  }
  statement {
    sid       = "CloudWatchAlarmOperations"
    actions   = ["cloudwatch:DeleteAlarms", "cloudwatch:DescribeAlarms"]
    resources = ["${local.arn_prefix.cw}:alarm:*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/AmazonECSManaged"
      values   = ["true"]
    }
  }
  statement {
    sid = "ELBReadOperations"
    actions = [
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeRules",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "VPCReadOperations"
    actions   = ["ec2:DescribeSecurityGroups", "ec2:DescribeSubnets", "ec2:DescribeRouteTables", "ec2:DescribeVpcs"]
    resources = ["*"]
  }
  statement {
    sid       = "CloudWatchLogsCreateOperations"
    actions   = ["logs:CreateLogGroup", "logs:TagResource"]
    resources = ["${local.arn_prefix.logs}:log-group:*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/AmazonECSManaged"
      values   = ["true"]
    }
  }
  statement {
    sid       = "CloudWatchLogsReadOperations"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "deployed_app_boundary" {
  name        = "${var.name_prefix}-deployed-app-boundary"
  description = "Permissions boundary for Sky-created roles (sky-core-*, sky-db-*)"
  policy      = data.aws_iam_policy_document.deployed_app_boundary.json
}

# ---------------------------------------------------------------------------
# 워커 역할
# ---------------------------------------------------------------------------

resource "aws_iam_role" "worker" {
  name               = "${var.name_prefix}-worker-task"
  description        = "Sky worker: runs jobs that create and remove deployed apps"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}

# 0) 큐 소비와 태스크 보호
data "aws_iam_policy_document" "worker_jobs" {
  statement {
    sid       = "WorkerOwnedExecutionGrants"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${var.artifacts_bucket_arn}/execution-grants/*"]
  }

  statement {
    sid = "ConsumeJobs"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
      "sqs:SendMessage", # 후속 작업
    ]
    resources = concat([var.queue_arn], var.shared_database_queue_arns)
  }
  statement {
    sid = "TaskScaleInProtection"
    # 작업 처리 중에는 축소·배포로 태스크가 내려가지 않도록 스스로 보호를 켠다.
    actions   = ["ecs:UpdateTaskProtection", "ecs:GetTaskProtection"]
    resources = ["arn:${local.partition}:ecs:${local.region}:${local.account}:task/${var.cluster_name}/*"]
  }
  statement {
    sid       = "DeleteBuildArtifacts"
    actions   = ["s3:DeleteObject"]
    resources = ["${var.artifacts_bucket_arn}/sources/*", "${var.artifacts_bucket_arn}/builds/*"]
  }
}

# 1) CloudFormation·ECS Express·ECR(sky-managed 조회·정리)
data "aws_iam_policy_document" "worker_deploy" {
  statement {
    sid = "ManagedStacks"
    actions = [
      "cloudformation:CreateStack",
      "cloudformation:DeleteStack",
      "cloudformation:DescribeStacks",
      "cloudformation:DescribeStackEvents",
      "cloudformation:ListStackResources",
      "cloudformation:UpdateTerminationProtection",
      "cloudformation:CreateChangeSet",
      "cloudformation:DescribeChangeSet",
      "cloudformation:ExecuteChangeSet",
      "cloudformation:DeleteChangeSet",
      "cloudformation:TagResource",
    ]
    resources = concat(
      local.managed_stack_arns,
      ["arn:${local.partition}:cloudformation:${local.region}:${local.account}:changeSet/*"],
    )
  }
  statement {
    sid       = "StackReadOnly"
    actions   = ["cloudformation:ListStacks", "cloudformation:GetTemplateSummary", "cloudformation:ValidateTemplate"]
    resources = ["*"]
  }

  statement {
    sid = "ExpressServices"
    actions = [
      "ecs:CreateExpressGatewayService",
      "ecs:UpdateExpressGatewayService",
      "ecs:DeleteExpressGatewayService",
      "ecs:DescribeExpressGatewayService",
      "ecs:ListServiceDeployments",
      "ecs:DescribeServiceDeployments",
      "ecs:DescribeServiceRevisions",
      "ecs:StopServiceDeployment",
    ]
    resources = [
      local.default_cluster_arn,
      "arn:${local.partition}:ecs:${local.region}:${local.account}:service/default/sky-*",
      "arn:${local.partition}:ecs:${local.region}:${local.account}:service-deployment/default/sky-*/*",
      "arn:${local.partition}:ecs:${local.region}:${local.account}:service-revision/default/sky-*/*",
    ]
  }
  statement {
    sid       = "ExpressDefaultCluster"
    actions   = ["ecs:CreateCluster"]
    resources = [local.default_cluster_arn]
  }
  statement {
    sid = "OneOffTasks"
    # 마이그레이션(sky-migrate-*)과 복원 검사(sky-restore-verify-*) 태스크만 default 클러스터에서 실행한다.
    actions = ["ecs:RunTask"]
    resources = [
      "arn:${local.partition}:ecs:${local.region}:${local.account}:task-definition/sky-migrate-*:*",
      "arn:${local.partition}:ecs:${local.region}:${local.account}:task-definition/sky-restore-verify-*:*",
    ]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [local.default_cluster_arn]
    }
  }
  statement {
    sid       = "RegisterOwnedTaskDefinitions"
    actions   = ["ecs:RegisterTaskDefinition"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/sky-managed"
      values   = ["true"]
    }
  }
  statement {
    sid       = "TagOnCreate"
    actions   = ["ecs:TagResource"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "ecs:CreateAction"
      values   = ["CreateExpressGatewayService", "RunTask", "RegisterTaskDefinition"]
    }
  }
  statement {
    sid = "EcsReadOnly"
    # 아래 작업은 자원 수준 제한을 지원하지 않거나 조회 전용이다.
    actions = [
      "ecs:DeregisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
      "ecs:ListTaskDefinitions",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
      "ecs:ListServices",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "ManagedRepository"
    # sky-core 스택이 레포를 만든다. 이미지 push는 빌드 워크플로(app-builder 역할)만 한다.
    actions = [
      "ecr:CreateRepository",
      "ecr:DeleteRepository",
      "ecr:DescribeRepositories",
      "ecr:PutImageScanningConfiguration",
      "ecr:TagResource",
      "ecr:ListTagsForResource",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:ListImages",
      "ecr:BatchDeleteImage",
    ]
    resources = [local.managed_repository_arn]
  }

  statement {
    sid       = "RdsPricing"
    actions   = ["pricing:GetProducts"]
    resources = ["*"]
  }
}

# 2) RDS·보안 그룹·로그·RDS 관리 비밀 (사용자 앱 DB)
data "aws_iam_policy_document" "worker_data" {
  statement {
    sid = "ManagedDatabases"
    actions = [
      "rds:CreateDBInstance",
      "rds:ModifyDBInstance",
      "rds:DeleteDBInstance",
      "rds:CreateDBSnapshot",
      "rds:RestoreDBInstanceFromDBSnapshot",
      "rds:CreateDBSubnetGroup",
      "rds:ModifyDBSubnetGroup",
      "rds:DeleteDBSubnetGroup",
      "rds:AddTagsToResource",
      "rds:ListTagsForResource",
    ]
    # 서비스 서버 상태 DB는 <name_prefix>-state 이므로 sky-* 범위에 든다. 아래 Deny로 따로 막는다.
    resources = [
      "arn:${local.partition}:rds:${local.region}:${local.account}:db:sky-*",
      "arn:${local.partition}:rds:${local.region}:${local.account}:snapshot:sky-*",
      "arn:${local.partition}:rds:${local.region}:${local.account}:subgrp:sky-db-*",
      "arn:${local.partition}:rds:${local.region}:${local.account}:og:default*",
      "arn:${local.partition}:rds:${local.region}:${local.account}:pg:default*",
    ]
  }
  statement {
    sid    = "DenyStateDatabase"
    effect = "Deny"
    # 스냅샷을 떠서 다른 이름으로 복원하면 상태 DB 내용을 꺼낼 수 있으므로 스냅샷·복원도 막는다.
    actions = [
      "rds:CreateDBSnapshot",
      "rds:RestoreDBInstanceFromDBSnapshot",
      "rds:ModifyDBInstance",
      "rds:DeleteDBInstance",
      "rds:RebootDBInstance",
      "rds:AddTagsToResource",
      "rds:RemoveTagsFromResource",
    ]
    resources = [
      "arn:${local.partition}:rds:${local.region}:${local.account}:db:${var.name_prefix}-*",
      "arn:${local.partition}:rds:${local.region}:${local.account}:snapshot:${var.name_prefix}-*",
    ]
  }
  statement {
    sid       = "DeleteAutomatedBackups"
    actions   = ["rds:DeleteDBInstanceAutomatedBackup"]
    resources = ["arn:${local.partition}:rds:${local.region}:${local.account}:auto-backup:*"]
  }
  statement {
    sid = "RdsReadOnly"
    actions = [
      "rds:DescribeDBInstances",
      "rds:DescribeDBSnapshots",
      "rds:DescribeDBSubnetGroups",
      "rds:DescribeDBEngineVersions",
      "rds:DescribeOrderableDBInstanceOptions",
    ]
    resources = ["*"]
  }
  statement {
    sid = "RdsManagedMasterSecret"
    # ManageMasterUserPassword: RDS가 호출자 권한으로 rds!* 비밀을 만들고 지운다.
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:TagResource",
      "secretsmanager:DeleteSecret",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecretVersionIds",
    ]
    resources = ["arn:${local.partition}:secretsmanager:${local.region}:${local.account}:secret:rds!*"]
  }
  statement {
    sid       = "RdsManagedMasterSecretKey"
    actions   = ["kms:DescribeKey"]
    resources = ["*"]
  }

  statement {
    sid = "Ec2ReadOnly"
    actions = [
      "ec2:DescribeVpcs",
      "ec2:DescribeSubnets",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSecurityGroupRules",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeAvailabilityZones",
    ]
    resources = ["*"]
  }
  statement {
    sid     = "CreateSecurityGroups"
    actions = ["ec2:CreateSecurityGroup"]
    resources = [
      "arn:${local.partition}:ec2:${local.region}:${local.account}:vpc/*",
      "arn:${local.partition}:ec2:${local.region}:${local.account}:security-group/*",
    ]
  }
  statement {
    sid       = "TagSecurityGroupsOnCreate"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:${local.partition}:ec2:${local.region}:${local.account}:security-group/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateSecurityGroup"]
    }
  }
  statement {
    sid = "ChangeOwnedSecurityGroups"
    # sky-managed=true 표식이 있는 그룹만 고치고 지운다. 서비스 서버 자체의 그룹은 해당하지 않는다.
    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:DeleteSecurityGroup",
    ]
    resources = ["arn:${local.partition}:ec2:${local.region}:${local.account}:security-group/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/sky-managed"
      values   = ["true"]
    }
  }

  statement {
    sid = "MigrationLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy",
      "logs:TagResource",
      "logs:TagLogGroup",
      "logs:ListTagsForResource",
      "logs:GetLogEvents",
    ]
    resources = ["arn:${local.partition}:logs:${local.region}:${local.account}:log-group:/sky/migrations/*"]
  }
}

# 3) 사용자 앱 IAM 역할 (sky-core, sky-db 스택). 권한 경계 필수.
data "aws_iam_policy_document" "worker_iam" {
  statement {
    sid = "ReadAndDeleteManagedRoles"
    actions = [
      "iam:GetRole",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = local.managed_role_arns
  }
  statement {
    sid = "ChangeManagedRolesWithBoundaryOnly"
    # 역할을 만들거나 정책을 바꿀 때 권한 경계가 우리 경계여야 한다.
    # CloudFormation 템플릿에 PermissionsBoundary를 넣어야 한다 (sky-platform 쪽 변경).
    actions = [
      "iam:CreateRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePermissionsBoundary",
    ]
    resources = local.managed_role_arns
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.deployed_app_boundary.arn]
    }
  }
  statement {
    sid       = "AttachKnownPoliciesWithBoundaryOnly"
    actions   = ["iam:AttachRolePolicy"]
    resources = local.managed_role_arns
    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = local.attachable_policy_arns
    }
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.deployed_app_boundary.arn]
    }
  }
  statement {
    sid       = "PassManagedRolesToEcsOnly"
    actions   = ["iam:PassRole"]
    resources = local.managed_role_arns
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com", "ecs.amazonaws.com"]
    }
  }
  statement {
    sid       = "ServiceLinkedRolesOnFirstUse"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:${local.partition}:iam::${local.account}:role/aws-service-role/*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "ecs.amazonaws.com",
        "ecs.application-autoscaling.amazonaws.com",
        "elasticloadbalancing.amazonaws.com",
        "rds.amazonaws.com",
      ]
    }
  }

  # 권한 상승 경로를 명시적으로 막는다. Allow보다 우선한다.
  statement {
    sid       = "DenyAssumeManagedRoles"
    effect    = "Deny"
    actions   = ["sts:AssumeRole"]
    resources = local.managed_role_arns
  }
  statement {
    sid    = "DenyTrustBoundaryAndPolicyVersionChanges"
    effect = "Deny"
    actions = [
      "iam:UpdateAssumeRolePolicy",
      "iam:DeleteRolePermissionsBoundary",
      "iam:CreatePolicyVersion",
      "iam:SetDefaultPolicyVersion",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "worker" {
  for_each = {
    jobs   = data.aws_iam_policy_document.worker_jobs.json
    deploy = data.aws_iam_policy_document.worker_deploy.json
    data   = data.aws_iam_policy_document.worker_data.json
    iam    = data.aws_iam_policy_document.worker_iam.json
  }
  name        = "${var.name_prefix}-worker-task-${each.key}"
  description = "Sky worker task role (${each.key})"
  policy      = each.value
}

resource "aws_iam_role_policy_attachment" "worker" {
  for_each   = aws_iam_policy.worker
  role       = aws_iam_role.worker.name
  policy_arn = each.value.arn
}

resource "aws_iam_role_policy_attachment" "worker_common" {
  role       = aws_iam_role.worker.name
  policy_arn = aws_iam_policy.task_common.arn
}
