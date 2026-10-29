# ---------------------------------------------------------------------------
# GitHub OIDC 역할에 넣는 인라인 정책 (역할 자체는 github-oidc 모듈이 만든다)
# ---------------------------------------------------------------------------

locals {
  state_bucket_arn = "arn:${local.partition}:s3:::${var.state_bucket_name}"
  state_object_arn = "${local.state_bucket_arn}/${var.state_key}"
  service_arns = [
    for name in values(var.service_names) :
    "arn:${local.partition}:ecs:${local.region}:${local.account}:service/${var.cluster_name}/${name}"
  ]
  task_definition_arns = [
    for name in values(var.service_names) :
    "arn:${local.partition}:ecs:${local.region}:${local.account}:task-definition/${name}:*"
  ]
}

# sky-platform (dev environment) → 서비스 서버 이미지를 ECR sky-platform에 push만 한다.
data "aws_iam_policy_document" "platform_deploy" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "PushPlatformImage"
    actions = [
      "ecr:DescribeRepositories", # push 전에 대상 레포가 있는지 확인한다 (ci.yml)
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
    ]
    resources = [var.platform_repository_arn]
  }
}

# sky-builder main → 사용자 앱 이미지(마이그레이션·복원 검사 이미지 포함)를 빌드해 ECR sky-managed에 push한다.
# 사용자 코드를 빌드하므로 AWS 권한은 push와 소스 읽기·결과 쓰기로만 제한한다.
data "aws_iam_policy_document" "app_builder" {
  statement {
    sid       = "NoRegistryLoginToken"
    effect    = "Deny"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "PushManagedImage"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:ListTagsForResource",
    ]
    resources = [local.managed_repository_arn]
  }
  statement {
    sid       = "ReadSources"
    actions   = ["s3:GetObject"]
    resources = ["${var.artifacts_bucket_arn}/sources/*", "${var.artifacts_bucket_arn}/execution-grants/*"]
  }
  statement {
    sid       = "WriteBuildResults"
    actions   = ["s3:PutObject"]
    resources = ["${var.artifacts_bucket_arn}/builds/*"]
  }
}

# sky-infra main → platform-image.auto.tfvars가 바뀌면 API·워커·outbox의 태스크 정의와 ECS 서비스만 -target으로 적용한다.
data "aws_iam_policy_document" "platform_release" {
  statement {
    sid = "StateList"
    # init이 워크스페이스 목록을 조회할 수 있어 접두어 조건을 걸지 않는다. 노출되는 것은 키 이름뿐이다.
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]
  }
  statement {
    sid       = "StateReadWrite"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = [local.state_object_arn]
  }
  statement {
    sid       = "StateLock"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.state_object_arn}.tflock"]
  }

  # 쓰기: 태스크 정의 등록과 서비스 갱신만
  statement {
    sid = "RegisterTaskDefinition"
    # RegisterTaskDefinition은 자원 수준 권한을 지원하지 않는다.
    actions   = ["ecs:RegisterTaskDefinition"]
    resources = ["*"]
  }
  statement {
    sid       = "TagTaskDefinitionOnRegister"
    actions   = ["ecs:TagResource"]
    resources = local.task_definition_arns
    condition {
      test     = "StringEquals"
      variable = "ecs:CreateAction"
      values   = ["RegisterTaskDefinition"]
    }
  }
  statement {
    sid       = "UpdatePlatformServices"
    actions   = ["ecs:UpdateService"]
    resources = local.service_arns
  }
  statement {
    sid     = "PassPlatformRoles"
    actions = ["iam:PassRole"]
    resources = concat(
      [for r in aws_iam_role.execution : r.arn],
      [aws_iam_role.api.arn, aws_iam_role.worker.arn],
    )
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # 배포 전 이미지 존재 확인
  statement {
    sid       = "CheckPlatformImage"
    actions   = ["ecr:DescribeImages"]
    resources = [var.platform_repository_arn]
  }

  # 읽기: -target은 의존 자원까지 refresh하므로 그 자원들의 조회 권한이 필요하다.
  # 대상: 클러스터·네트워크·ALB·ACM·Route 53·Cognito·상태 DB·버킷·큐·IAM·로그 그룹·ECR·비밀(메타데이터만)
  statement {
    sid = "ReadTargetDependencies"
    actions = [
      "sts:GetCallerIdentity",
      "ecs:Describe*",
      "ecs:List*",
      "ec2:Describe*",
      "elasticloadbalancing:Describe*",
      "acm:DescribeCertificate",
      "acm:ListTagsForCertificate",
      "route53:GetHostedZone",
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
      "route53:ListResourceRecordSets",
      "route53:GetChange",
      "route53:ListTagsForResource",
      "cognito-idp:DescribeUserPool",
      "cognito-idp:DescribeUserPoolClient",
      "cognito-idp:DescribeUserPoolDomain",
      "cognito-idp:GetUserPoolMfaConfig",
      "cognito-idp:ListTagsForResource",
      "rds:DescribeDBInstances",
      "rds:DescribeDBSubnetGroups",
      "rds:DescribeDBParameterGroups",
      "rds:DescribeDBParameters",
      "rds:ListTagsForResource",
      "logs:DescribeLogGroups",
      "logs:ListTagsForResource",
      "logs:ListTagsLogGroup",
      "ecr:DescribeRepositories",
      "ecr:ListTagsForResource",
    ]
    resources = ["*"]
  }
  statement {
    sid = "ReadArtifactsBucketConfig"
    actions = [
      "s3:GetBucket*",
      "s3:GetAccelerateConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration",
      "s3:GetEncryptionConfiguration",
      "s3:ListBucket",
    ]
    resources = [var.artifacts_bucket_arn]
  }
  statement {
    sid       = "ReadQueues"
    actions   = ["sqs:GetQueueAttributes", "sqs:ListQueueTags"]
    resources = ["arn:${local.partition}:sqs:${local.region}:${local.account}:${var.name_prefix}-*"]
  }
  statement {
    sid = "ReadPlatformIam"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyTags",
    ]
    resources = [
      "arn:${local.partition}:iam::${local.account}:role/${var.name_prefix}-*",
      "arn:${local.partition}:iam::${local.account}:policy/${var.name_prefix}-*",
    ]
  }
  statement {
    sid = "ReadSecretMetadata"
    # 값(GetSecretValue)은 읽지 않는다.
    actions   = ["secretsmanager:DescribeSecret", "secretsmanager:GetResourcePolicy"]
    resources = var.platform_secret_arns
  }
}
