# 온프레미스 VM 준비 (Ansible)

이미 있는 Debian/Ubuntu VM을 Sky의 `onprem-vm` 배포 대상으로 준비한다. VM을 만들지는 않는다.
Sky는 Docker SSH transport(`ssh://sky@<host>`)로 이 VM에 접속해 이미지를 빌드하고 Compose로 실행한다
(sky-platform `docs/onprem-vm.md`).

`site.yml`이 하는 일:

| 단계 | 내용 |
| --- | --- |
| Docker | Docker 공식 apt 저장소에서 Engine, Buildx, Compose 플러그인 설치. **서명 키 지문을 확인한 뒤에만** 저장소 추가 |
| 로그 | 컨테이너 로그 회전(10MB × 3), `live-restore` |
| 계정 | 배포 전용 `sky` 계정(비밀번호 없음, `docker` 그룹), 넘겨준 ed25519 공개 키 하나만 등록 |
| SSH | 비밀번호·키보드 인증과 root 로그인 끄기 (`sshd -t`로 검증 후 적용) |
| 확인 | `sky` 계정으로 `docker info`, `docker compose version` 실행. SSH 호스트 키 지문 출력 |

`docker` 그룹은 사실상 VM root 권한이다. **Sky 전용 VM**에만 적용한다.

## 실행

Ansible core 2.17 이상이 필요하다. 이 플레이북은 core 내장 모듈만 쓴다(컬렉션 설치 불필요).

```sh
python3 -m venv .venv && .venv/bin/pip install 'ansible-core>=2.17,<2.20'

# Sky 서버가 쓸 배포 키 (개인 키는 Sky 서버에만 둔다)
ssh-keygen -t ed25519 -N "" -C sky-deploy -f sky_deploy_key

cp inventory.example.ini inventory.ini   # VM 주소와 sudo 가능한 관리자 계정 입력
.venv/bin/ansible-playbook -i inventory.ini site.yml \
  -e "sky_ssh_public_key='$(cat sky_deploy_key.pub)'"
```

설정이 같으면 변경 없이 재실행할 수 있도록 구성했다. 실제 적용 전에는 별도 VM에서 실행 조건을 확인한다.

문법 검사(대상 VM에 접속하지 않음):

```sh
.venv/bin/ansible-playbook -i inventory.example.ini site.yml --syntax-check
```

Docker 저장소 등록에 필요한 `python3-debian`도 대상 VM에 설치한다. 지원 아키텍처는 x86_64·aarch64다.

## Sky 서버에 등록

1. 플레이북 마지막에 나온 **호스트 키 지문을 VM 콘솔 등 별도 경로로 대조**한 뒤 `known_hosts`에 넣는다.
   ```sh
   ssh-keyscan -t ed25519 <vm> > vm_known_hosts
   ssh-keygen -lf vm_known_hosts   # 플레이북 출력의 ED25519 지문과 같아야 한다
   ```
2. Sky 서버 계정의 SSH 설정에 배포 키와 `known_hosts`를 연결한다.
   ```
   Host <vm>
     User sky
     IdentityFile ~/.ssh/sky_deploy_key
     IdentitiesOnly yes
     StrictHostKeyChecking yes
   ```
3. Sky 서버 환경변수를 설정한다.
   ```sh
   export SKY_VM_SSH_HOST=<vm>
   export SKY_VM_SSH_USER=sky
   export SKY_VM_PUBLIC_HOST=<사용자가 접속할 VM 주소>
   ```

## 네트워크

Docker가 배정하는 호스트 포트(기본 32768번대)로 앱이 열린다. Sky는 `SKY_VM_PUBLIC_HOST:<포트>`에서
HTTP 200을 확인해야 성공으로 기록한다. 이 포트들을 Sky 서버와 접속 사용자에게 열어야 한다.

- Docker가 게시한 포트는 `ufw` 규칙을 우회한다. 접근 제한은 VM 바깥 방화벽(클라우드 보안 그룹, 사내 방화벽)이나
  Docker의 `DOCKER-USER` 체인으로 한다.
- HTTPS와 인터넷 공개 주소는 이 플레이북 범위가 아니다(Sky `onprem-vm`도 HTTP만 지원).
