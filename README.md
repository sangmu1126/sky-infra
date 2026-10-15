# sky-infra

Sky 서비스 서버가 올라갈 AWS 인프라의 Terraform과 기존 Linux VM의 Ansible 준비 구성을 관리합니다.
[팀 원본](https://github.com/SoftBank-Hydrogen/sky-infra)을 바탕으로 개인적으로 유지·보완하는 저장소입니다. AWS 호스팅 구조는 **B안**입니다.
- 컴퓨트: ECS Fargate의 API 서비스와 워커 서비스
- 상태·파일·작업 전달: RDS PostgreSQL(Multi-AZ), S3, SQS
- 사용자 앱 빌드: GitHub Actions

사용자 앱(배포 서버)의 자원은 [`sky-platform`](https://github.com/sangmu1126/sky-platform)이 실행 중에 만들고 지웁니다. 두 저장소는 같은 자원을 동시에 관리하지 않습니다.

설계와 결정 근거는 [`docs/design-b.md`](docs/design-b.md)에 있습니다. sky-platform이 맞춰야 할 계약(환경변수, 워커 동작, CloudFormation 권한 경계)은 그 문서 7장에 있습니다.

## 디렉터리

| 경로 | 내용 |
|---|---|
| `terraform/bootstrap/` | 공용 Terraform state용 S3 버킷. 계정마다 한 번, 로컬 state |
| `terraform/envs/dev/` | 개발 환경 루트. 모든 모듈을 연결한다 |
| `terraform/modules/` | 모듈 (아래 표) |
| `scripts/` | 이미지 배포 plan 범위 검사 스크립트와 테스트 |
| [`ansible/onprem-vm/`](ansible/onprem-vm/) | 기존 Debian/Ubuntu VM의 Docker·Compose·배포 계정·SSH 준비 |
| `.github/workflows/onprem.yaml` | Ansible 문법 검사. VM에 접속하거나 변경하지 않음 |
| `.github/workflows/terraform.yaml` | 정적 검사·mock plan, PR plan, 승인 후 apply |
| `.github/workflows/deploy.yaml` | 서비스 서버 이미지 배포 (SHA 파일만 바뀐 변경) |

## 온프레미스 VM 준비

이미 있는 Debian/Ubuntu VM은 [Ansible 실행 안내](ansible/onprem-vm/README.md)를 따라 준비합니다. AWS Terraform 적용과 독립적이며 AWS 계정 없이 사용할 수 있습니다.

VM 생성, 사용자 앱 배포, HTTPS 구성은 이 플레이북의 범위가 아닙니다. 앱 배포는 준비 후 개인 `sky-platform`의 `onprem-vm` 어댑터로 실행합니다. 실제 인벤토리·개인 키는 Git에서 제외합니다.

## 모듈

| 모듈 | 만드는 것 |
|---|---|
| `network` | VPC, 퍼블릭·앱·데이터 서브넷(2 AZ), NAT(AZ별), S3 엔드포인트, 보안 그룹(alb, app, worker, data) |
| `edge` | ACM 인증서, ALB, Route 53 레코드(호스팅 영역은 읽기만), Cognito 로그인 |
| `ecr` | ECR `sky-platform` (서비스 서버 이미지) |
| `secrets` | Secrets Manager 비밀 이름 (OpenAI, GCP, GitHub App 키). 값은 넣지 않는다 |
| `state-db` | 상태 DB (RDS PostgreSQL, Multi-AZ, 관리형 마스터 비밀) |
| `artifacts` | 파일 저장소 S3 버킷 |
| `queue` | 작업 큐 SQS FIFO + DLQ |
| `ecs-cluster` | Fargate 클러스터 |
| `ecs-service` | Fargate 서비스 하나 (태스크 정의, 서비스, 오토스케일링). API·워커가 각각 쓴다 |
| `iam` | 실행 역할, API·워커 태스크 역할, 사용자 앱 권한 경계, GitHub 역할 정책 |
| `github-oidc` | GitHub Actions OIDC 공급자와 역할 |
| `observability` | 로그 그룹, SNS 토픽, ALB·큐·DB 알람 |
| `published-outputs` | sky-platform·sky-builder CI가 읽는 SSM 값 |

## 로컬 검사 (AWS 계정 없이)

```sh
terraform fmt -check -recursive terraform
terraform -chdir=terraform/bootstrap init -backend=false && terraform -chdir=terraform/bootstrap validate
terraform -chdir=terraform/envs/dev init -backend=false && terraform -chdir=terraform/envs/dev validate
terraform -chdir=terraform/envs/dev test          # mock provider로 빈 계정 첫 plan
python3 -m unittest discover -s scripts
```

Terraform 1.10 이상이 필요하며, CI는 1.15.8을 씁니다.

## 처음 적용 (담당자 한 명, 수동)

새 계정에 적용할 때 사용하는 절차입니다. 기존 팀 환경의 적용 이력과 개인 계정의 신규 구성을 구분해야 합니다.

현재 Terraform에는 기존 환경을 가져오는 `imports.tf`와 계정·저장소 ID 설정이 있습니다. **새 개인 계정에서는 기존 리소스 존재 여부와 import ID, GitHub OIDC 대상, DNS·이미지·시크릿을 먼저 맞춰야 합니다.** 아래 명령만으로 과거 데이터까지 복원되지는 않습니다. 기존 state가 있다면 먼저 보존·확인합니다.
- 비밀 값이 없거나 이미지가 없으면 태스크가 뜨지 않으므로 ECR과 비밀을 먼저 만듭니다.
- A안(`sky-infra-v0`)을 같은 state 키로 적용한 적이 있다면 [`docs/design-b.md`](docs/design-b.md) 9장을 먼저 봅니다.

```sh
# 0. state 버킷 (계정당 한 번). 생긴 로컬 state 파일은 커밋하지 않고 비공개 장소에 보관한다.
terraform -chdir=terraform/bootstrap init && terraform -chdir=terraform/bootstrap apply

cd terraform/envs/dev
cp backend.hcl.example backend.hcl                 # bucket을 bootstrap 출력값으로
cp terraform.tfvars.example terraform.tfvars       # aws_account_id
terraform init -backend-config=backend.hcl

# 1. ECR과 비밀 이름만 먼저
terraform apply -target=module.ecr -target=module.secrets

# 2. 서비스 서버 이미지 push (docs/design-b.md 7장 계약을 구현한 이미지. 없으면 /health만 응답하는 임시 이미지)
REPO=$(terraform output -raw ecr_repository_url)
SHA=$(git -C <sky-platform 경로> rev-parse --short=7 HEAD)
aws ecr get-login-password | docker login --username AWS --password-stdin "${REPO%%/*}"
docker build --platform linux/amd64 -t "$REPO:$SHA" <빌드 경로> && docker push "$REPO:$SHA"
sed -i "s/^platform_image_tag = .*/platform_image_tag = \"$SHA\"/" platform-image.auto.tfvars

# 3. 비밀 값
aws secretsmanager put-secret-value --secret-id sky-dev/openai-api-key --secret-string '<키>'
aws secretsmanager put-secret-value --secret-id sky-dev/gcp-service-account-key --secret-string file://gcp-key.json
aws secretsmanager put-secret-value --secret-id sky-dev/github-app-private-key --secret-string file://github-app.pem

# 4. 권한 경계 대조 (docs/design-b.md 5.3). 2026-10-10 완료. 관리형 정책 버전이 바뀌었을 때만 다시 한다

# 5. 전체 적용
terraform plan -out=dev.tfplan     # 검토
terraform apply dev.tfplan
terraform output
```

그다음 할 일입니다.

1. **GitHub 저장소 변수(sky-infra).** `terraform output github_role_arns`에서 값을 가져와 넣습니다.
   - `AWS_ACCOUNT_ID`, `AWS_REGION`, `TF_STATE_BUCKET`
   - `AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN`, `AWS_PLATFORM_RELEASE_ROLE_ARN`, `INFRA_APPLY_POLICY_ARNS`
2. **main 브랜치 보호(sky-infra).** `deploy / plan`과 `terraform / static`을 필수 상태 검사로 지정합니다.
3. **sky-platform CI.** `ci.yml`의 `publish-service` job이 이미지를 push합니다.
   - 저장소 변수: `AWS_SERVICE_CI_ROLE_ARN`(= `github_role_arns["platform-deploy"]`), `SKY_SERVICE_ECR_REPOSITORY`(= `sky-platform`), `AWS_ACCOUNT_ID`, `AWS_REGION`
   - **`dev` environment의 배포 브랜치를 `main`으로 제한합니다.** 역할이 `environment:dev`를 신뢰하므로, 제한하지 않으면 다른 브랜치의 워크플로도 이 역할을 받을 수 있습니다.
4. **sky-builder 저장소.** [`docs/design-b.md`](docs/design-b.md) 8장대로 만듭니다.
5. **Cognito 사용자.** `terraform output cognito_user_pool_id`의 풀에 관리자가 직접 만듭니다.
6. **알람 수신.** `alarm_topic_arn` 토픽에 이메일을 구독합니다.

## 서비스 서버 이미지 배포

```sh
# ECR sky-platform에 <SHA> 이미지가 있는 상태에서
git switch -c deploy/<SHA>
sed -i 's/^platform_image_tag = .*/platform_image_tag = "<SHA>"/' terraform/envs/dev/platform-image.auto.tfvars
git commit -am "Deploy sky-platform <SHA>"
git push -u origin deploy/<SHA>   # PR → plan 코멘트 확인 → 머지하면 자동 배포
```

- SHA PR은 **그 파일 하나만** 바꿉니다. 다른 파일이 섞이면 검사가 실패합니다.
- main에 적용하지 않은 인프라 변경이 있으면 의존 자원 차이가 plan에 잡혀 이미지 배포가 막힙니다. 먼저 apply합니다.
- 로컬 `terraform.tfvars`에는 CI가 저장소 변수로 받는 값만 둡니다. CI는 이 파일을 보지 못하고 기본값으로 plan하기 때문입니다.
- API와 워커는 무중단 롤링 배포입니다. 처리 중인 워커 작업은 끝날 때까지 이전 태스크에서 계속됩니다.
