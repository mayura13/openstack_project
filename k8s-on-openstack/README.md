# OpenInfra Lab Kit — Kubernetes on OpenStack

Bare Metal 서버 한 대에서 **OpenStack을 먼저 구축하고, 그 위의 VM 3대에 Kubernetes를 올리는** 실습 환경을 일곱 단계(0~6)로 구축하고 검증하는 입문자용 자동화 키트입니다.

> **현재 상태: 설계·수동 구축 완료, 자동화 코드 작성 완료(검증 진행 중)**
> 0~6단계 자동화 코드(`stage0/`~`stage6/`, `common/`, `versions.env`, `Makefile`)가 작성되었습니다. 0~4단계는 구축된 서버에서 읽기 전용 점검(preflight, dry-run, postcheck)으로 확인했습니다. 5단계는 NotReady 클러스터에 실제 apply 를 실행했고, 6단계는 실제 클러스터를 삭제해 검증 f 를 통과했습니다. 삭제 뒤 같은 주문서로 4·5단계를 다시 실행하는 재생성도 시험했습니다. 깨끗한 서버에서의 설치와 0~3단계의 변경 경로(Docker·OpenStack 배포, 이미지 빌드, kind 생성), 4단계의 ORC 설치·Secret 생성 경로는 아직 시험하지 않았습니다.
> 0~6단계의 수동 구축을 모두 한 번씩 수행해 절차, 고정 버전, 막힌 지점을 기록했습니다. 이 README는 그 기록을 바탕으로 키트가 **무엇을 어떤 순서로 자동화할지**를 정리한 것이며, 아래 `make` 명령과 디렉터리는 자동화 구현과 함께 채워집니다. 구현된 항목은 [구현 현황](#구현-현황)에서 확인하세요.

---

## 1. 이 키트가 하는 일

- 새로운 플랫폼이 아닙니다. 기존 오픈소스 도구(Kolla-Ansible, Terraform, image-builder, kind, Cluster API, Calico, OCCM)를 **올바른 순서와 설정으로 연결**하는 자동화 계층입니다.
- 단계마다 선행 조건 검사, 실행, 종료 후 검증을 두고, 실패하면 **어느 단계의 어떤 항목에서 왜 실패했는지**를 출력한 뒤 중단합니다.
- 단계 사이에서 값을 자동으로 넘깁니다. 예를 들어 Terraform이 만든 네트워크·flavor·키페어·이미지 이름이 CAPO 클러스터 매니페스트에 들어갑니다.
- 단계별 로그와 소요 시간을 남깁니다.
- 평가(성공률, 결과 일관성, 자동화 수준의 측정과 집계)는 키트가 자동화하지 않습니다. 키트는 평가에 필요한 로그와 O/X 출력까지만 제공합니다.

자매 키트인 **OpenStack on Kubernetes**(VM 4대 → Kubernetes → OpenStack-Helm)와 단계 틀(0~6단계, preflight → 실행 → postcheck)을 공유합니다.

## 2. 구조

```
Bare Metal 호스트 (Ubuntu 24.04, 단일 NIC)
 ├─ OpenStack 2026.1 (Kolla-Ansible, all-in-one, 컨테이너 33개)
 │    └─ CAPO가 만든 VM 3대 ─ Kubernetes v1.36.6
 │         ├─ control-plane × 1
 │         └─ worker × 2
 └─ kind 관리 클러스터 (Docker) ─ Cluster API + CAPO
```

| 구성 | 값 |
| --- | --- |
| 노드 VM | control-plane 1대 + worker 2대, 각 4 vCPU · 8GiB · 60GB (합계 12 vCPU · 24GiB · 180GB) |
| 노드 OS | Ubuntu 24.04 (image-builder로 직접 빌드한 이미지) |
| CNI / 클라우드 연동 | Calico(IPIP) / OpenStack Cloud Controller Manager(OCCM) |
| 외부 네트워크 | flat `physnet1`, `10.20.20.0/24`, 호스트의 veth 쌍과 NAT로 구성 |

**두 종류의 자원 수명**을 구분합니다. 이 구분이 검증 f의 기준입니다.

| 만드는 도구 | 자원 | 삭제 시 |
| --- | --- | --- |
| Terraform (공용 기반) | 외부·내부 네트워크, 서브넷, 라우터, flavor, 키페어, 노드 이미지 등록 | 클러스터를 지워도 **남아야 함** |
| CAPO (클러스터) | 노드 VM 3대, 포트, 보안 그룹 2개, API 서버 Floating IP | 클러스터 삭제 시 **모두 정리되어야 함** |

Terraform은 노드 VM을 만들지 않습니다. 노드 VM은 CAPO가 OpenStack API로 만듭니다.

## 3. 단계 구성

| 단계 | 내용 | 도구 | 끝났을 때 상태 |
| --- | --- | --- | --- |
| 0 | 환경 점검, 도구 설치 | 쉘 스크립트 | 가상환경, `/etc/kolla`, 인벤토리, 비밀번호 파일, 도구 4종(kubectl, terraform, kind, clusterctl) 준비 |
| 1 | Docker 설치(`bootstrap-servers`), OpenStack 구축 | Kolla-Ansible 22.2.0 | 서비스 7개 등록, 컴퓨트·네트워크 에이전트 up |
| 2 | 노드 이미지 + 공용 기반 자원 + **검증 a** | image-builder, Terraform | 이미지 active, 자원 9개, 테스트 VM이 KVM으로 부팅 |
| 3 | 관리 클러스터 | kind, clusterctl | CAPI·CAPO 컨트롤러 Running |
| 4 | 워크로드 클러스터 생성 | Cluster API + CAPO | 노드 VM 3대 ACTIVE, 노드 NotReady(정상) |
| 5 | 클러스터 구성 요소 + **검증 b~e** | Calico, OCCM | 노드 3대 Ready, OCCM 연동 |
| 6 | 삭제와 **검증 f** | 검증 스크립트 | CAPO 자원 정리, Terraform 자원 보존 |

단계 번호는 팀 일정표(WBS)와 일치하는지 확인이 필요합니다.

## 4. 검증 수준

각 항목은 O/X로 판정하고, 실패하면 단계와 항목을 출력합니다.

| 수준 | 확인 항목 | 실행 시점 |
| --- | --- | --- |
| a. OpenStack 기반 | 인증, 이미지 조회, 네트워크 생성, 테스트 VM의 KVM 부팅 | 2단계 후 |
| b. 클러스터 생성 | CAPO가 만든 노드 VM 3대 ACTIVE, Kubernetes 노드 3대 Ready | VM은 4단계 후, Ready는 5단계 후 |
| c. 배포 상태 | 실행 중인 Pod의 Ready, 일회성 Job의 Complete | 5단계 후 |
| d. 서비스 동작 | 서로 다른 워커 사이의 Pod 통신, DNS 조회, Service 접근 | 5단계 후 |
| e. 클라우드 연동 | 노드의 `providerID`와 IP가 실제 OpenStack VM과 일치 | 5단계 후 |
| f. 삭제 | CAPO 자원 정리, Terraform 자원 보존을 이름·ID로 각각 비교 | 6단계 |

검증 범위 밖입니다: Cinder CSI 볼륨, 로드밸런서·Ingress, 고가용성 제어 플레인, 성능.

## 5. 고정 버전

모든 버전은 `versions.env` 한 곳에서 관리하며 `latest` 태그를 쓰지 않습니다. 아래는 수동 구축에서 실제로 동작을 확인한 조합입니다. 이 조합이 각 프로젝트의 공식 검증 세트라는 뜻은 아닙니다.

| 분류 | 항목 | 버전 |
| --- | --- | --- |
| 호스트 | OS | Ubuntu 24.04 LTS |
| OpenStack | 릴리스 / Kolla-Ansible / 이미지 태그 | 2026.1 / 22.2.0 / `2026.1-ubuntu-noble` |
| | ansible-core (Kolla 가상환경) | 2.20.11 |
| | python-openstackclient / openstacksdk | 10.5.0 / **4.22.0 고정** |
| 노드 이미지 | image-builder | 커밋 `704689a7e24c` |
| | Packer / ansible-core (별도 가상환경) | v1.9.5 / 2.18.18 |
| | Kubernetes / containerd | 1.36.6 / 2.3.7 |
| 공용 자원 | Terraform / OpenStack provider | 1.15.9 / 3.4.0 |
| 관리 클러스터 | kind / 노드 이미지 | v0.33.0 / `kindest/node:v1.36.4@sha256:099e0493…` |
| | clusterctl, Cluster API / CAPO / ORC | v1.14.3 / v0.15.1 / v2.0.3 |
| 클러스터 구성 | Calico / OCCM | v3.33.0 / v1.36.0 |

- openstacksdk 4.23.0은 `defaults.json` 누락으로 CLI가 동작하지 않아 4.22.0으로 고정했습니다.
- kind 기본 노드 이미지(Kubernetes 1.37.0)는 Cluster API v1.14의 관리 클러스터 지원 범위(1.33~1.36) 밖이라 이미지를 digest까지 지정합니다.
- OCCM 매니페스트는 `master`가 아닌 `v1.36.0` 태그로 고정합니다.

## 6. 요구 사항

수동 구축을 수행한 환경 기준입니다. 0단계 점검의 최소 기준값은 첫 자동화 구축 후 실측해 정합니다.

| 항목 | 수동 구축 환경 |
| --- | --- |
| 서버 | Bare Metal 1대, CPU 96스레드, 메모리 125GiB, 디스크 464GB |
| OS | Ubuntu 24.04, `sudo` 가능한 일반 계정 |
| 가상화 | `/dev/kvm`과 CPU 가상화 플래그(vmx) 필수 (노드 VM이 KVM으로 부팅) |
| 네트워크 | 인터넷 접속: apt, PyPI, GitHub, opendev.org, Galaxy, quay.io, registry.k8s.io, ghcr.io, docker.io, pkgs.k8s.io, registry.terraform.io |
| NIC | 물리 NIC 1개(단일 NIC). 키트가 `kolla0`(dummy)와 `veth-ext`/`veth-host`로 Kolla의 2-NIC 요구를 대체 |

**호스트를 변경하는 작업이 있습니다.** 원격 접속(SSH)에 영향을 줄 수 있는 작업은 실행 전에 영향과 복구 방법을 출력하고 사용자 확인을 받습니다.

- 호스트 libvirt 중지: `libvirtd`뿐 아니라 `virtlogd`/`virtlockd`도 함께 중지해야 합니다(Kolla의 `nova_libvirt`와 충돌).
- 호스트 네트워크: `kolla0`, veth 쌍, 방화벽 허용·NAT 규칙, `ip_forward`. 기존 방화벽 파일과 `eth0` 설정은 수정하지 않습니다.
- 호스트에 상시 방화벽 체인이 있는 환경이면 `FORWARD`에 kind → 외부망 허용 규칙이 추가로 필요합니다.
- `docker` 그룹 추가: 적용하려면 **다시 로그인**해야 합니다. 이미 떠 있는 tmux 서버도 이전 그룹을 유지합니다.

## 7. 사용법

```bash
cd <키트 폴더>

make preflight         # 0단계 설치 전 점검만
make install           # 0단계 도구 설치까지
make up                # 0~5단계 순서대로(미시험, 아래 설명 참고)
make reset-plan        # 초기화 계획만 출력(아무것도 지우지 않음)
make reset             # 초기화 실행(미시험, 아래 설명 참고)
make stage-N           # N단계 전체(preflight -> apply -> postcheck). N = 0..6
make stageN-plan       # N단계가 무엇을 바꿀지만 출력(dry-run). N = 1..6
make verify            # 검증 a~f 전체. 상황에 맞는 것만 실행하고 삭제는 하지 않음
make stage-6           # 6단계: 클러스터 삭제와 검증 f. 클러스터 이름을 직접 입력해야 진행
```

- `make up`은 0~5단계를 순서대로 실행합니다. 중간에 실패하면 멈추고, 이미 끝난 단계는 SKIP 하므로 다시 실행해도 됩니다. 0단계가 종료 코드 2(재로그인 필요)로 끝나면 다시 접속한 뒤 `make up`을 재실행하세요. 이미지 빌드(2단계)와 OpenStack 배포(1단계)가 있어 tmux 안에서 실행해야 합니다. **`make up` 전체는 아직 시험하지 않았습니다**(단계별 시험 범위는 구현 현황 표 참고).
- `make reset-plan`은 지울 대상의 **이름과 ID**(OpenStack 서버, Terraform 자원, kind, Docker, 호스트 네트워크)를 보여 주고 계획만 출력합니다. `make reset`은 안쪽부터 워크로드 클러스터(6단계) → Terraform destroy와 삭제 확인 → kind → Kolla destroy → 상태 파일·설정·도구 → 호스트 네트워크 순으로 지웁니다. Terraform 상태 파일은 OpenStack 자원이 실제로 사라졌음을 목록 조회로 확인한 뒤에만 지우고, 조회가 실패하면 지워졌다고 보지 않습니다. 백업 해시 확인, tmux, 호스트 이름 입력을 요구하고 물리 NIC와 기존 방화벽 파일은 건드리지 않습니다. 옵션은 `RESET_OPTS="--with-docker --keep-node-image"`처럼 넘깁니다. **실제 서버에서 시험하지 않았습니다.**
- 검증은 `verify-a`(OpenStack, 테스트 VM은 항상 삭제), `verify-bcde`(클러스터가 있을 때), `verify-f`(삭제 전후 기록이 있을 때)를 개별로도 실행할 수 있고, `make verify`가 이 셋을 묶어 표로 요약합니다. 클러스터를 삭제한 뒤에는 b~e가 SKIP되는 것이 정상이고, 삭제 뒤 다시 만들었다면 f가 SKIP됩니다(삭제 검증은 삭제 직후의 기록과 비교하는 것이라 재생성 뒤에는 의미가 없음).
- 오래 걸리는 단계(노드 이미지 빌드 약 31분, OpenStack 배포 약 23분)는 **tmux 같은 별도 세션**에서 실행하세요. SSH가 끊겨도 계속 진행됩니다.
- 확인 질문이 있는 명령의 출력을 `| tail` 같은 파이프로 가리지 않습니다. 승인 질문이 숨어 진행이 멈춘 것처럼 보입니다.
- 삭제는 되돌릴 수 없으므로 클러스터 이름을 직접 입력해야 하고(`--yes`로는 건너뛸 수 없음), 삭제 전에 OpenStack 자원 상태를 기록해 삭제 후 이름·ID로 비교합니다.

## 8. 디렉터리 구조

```
.
├── README.md
├── Makefile             # preflight / install / stage-N / stageN-plan / verify
├── versions.env         # 모든 버전·이미지 태그 한 곳에 고정
├── common/              # 공통 함수: 단계 실행 래퍼, 로그·소요 시간, 실패 메시지 형식
├── stage0/              # 점검 · 도구 설치 · 설치 후 점검
├── stage1/              # Kolla-Ansible 설정과 실행, 호스트 네트워크
├── stage2/              # 노드 이미지 빌드, Terraform 공용 자원(terraform/), 검증 a
├── stage3/              # kind 관리 클러스터, clusterctl init
├── stage4/              # CAPO 클러스터 주문서 템플릿, ORC
├── stage5/              # Calico, OCCM, 검증 b~e
├── stage6/              # 클러스터 삭제, 검증 f(삭제 전후 비교)
├── verify/              # 검증 a~f 전체 실행(all.sh)
└── logs/                # 단계별 로그, 소요 시간 (git 제외)
```

가이드북(`docs/`, RST/Sphinx)과 평가 기록용 템플릿(`eval/`)은 키트 저장소 밖에서 작성합니다.

## 9. 자주 만나는 문제

수동 구축에서 실제로 막혔던 지점입니다. 자동화는 이 증상을 진단 메시지로 바꿉니다.

| 단계 | 증상 | 원인 | 조치 |
| --- | --- | --- | --- |
| 1 | `Hostname has to resolve uniquely to the IP address of api_interface` | 호스트 이름이 `localhost` | 호스트 이름 변경, `/etc/hosts`와 인벤토리 수정 |
| 1 | `/var/run/libvirt/libvirt-sock` 점검 실패 | 호스트 libvirtd 실행 중 | 호스트 libvirt 서비스·소켓 중지 |
| 1 | MariaDB `Address already in use` | `enable_proxysql` 기본값 yes로 3306 점유 | `enable_proxysql: "no"` |
| 1 | `Could not read clouds.yaml configuration file` | openstacksdk 4.23.0에 파일 누락 | `openstacksdk==4.22.0` |
| 2 | VM `ERROR`, `console.log: No such file or directory` | 호스트 `virtlogd`/`virtlockd` 실행 중(가설) | 호스트 `virtlogd`/`virtlockd` 중지, `nova_libvirt` 재시작 |
| 2 | 이미지 빌드가 `/dev/kvm` 접근 불가 | 장치 그룹이 `kvm`이 아님 | 실행 사용자에게 접근 허용(`setfacl`, 재부팅이나 장치 재생성 시 사라질 수 있음) |
| 3 | `clusterctl init`이 10분 후 `context deadline exceeded` | Kolla가 Docker `iptables:false`로 설정해 컨테이너 대역 NAT 없음 | kind 대역 `MASQUERADE` 규칙 추가 |
| 4 | CAPO `CrashLoopBackOff`, webhook `connection refused` | CAPO v0.15.1은 ORC가 필수 | ORC 설치 후 CAPO 재시작 |
| 4 | `INITIALIZED` 비어 있고 워커 Pending | 호스팅 방화벽이 `FORWARD`에서 6443 등을 REJECT | kind → 외부망 `FORWARD` 허용 규칙 |
| 5 | OCCM `Error` 반복, `No suitable endpoint ... service catalog` | Octavia(LB) 없음 | `cloud.conf`에 `[LoadBalancer] enabled=false` |
| 5 | 컨트롤플레인 `calico-node`만 BIRD 시작 실패 | 보안 그룹에 Typha 5473/tcp 없음. **`openstack`으로 직접 넣은 규칙은 CAPO 가 되돌린다**(관찰: 넣은 지 수 분 뒤 CAPO 의 보안 그룹 재조정 시각과 SG 수정 시각이 같음) | 4단계 주문서의 `managedSecurityGroups.clusterNodesSecurityGroupRules` 에 5473/tcp 규칙을 넣는다(키트가 렌더) |

## 10. 비밀과 공개 규칙

이 저장소는 공개를 전제로 합니다. 아래는 저장소와 공유 로그에 **넣지 않습니다.** `.gitignore`에 미리 등록합니다.

- `/etc/kolla/passwords.yml`, `admin-openrc.sh`, `clouds.yaml`
- kubeconfig(관리·워크로드 클러스터 모두), OCCM `cloud.conf`와 시크릿 YAML
- `terraform.tfstate*`, `.terraform/`, SSH 개인 키(`k8s-node-key`)
- 서버 공인 IP, 계정 이름 (문서에서는 `<SERVER_IP>`, `<USER>`로 표기)

`source admin-openrc.sh` 후에는 `env`/`printenv` 출력을 피하세요(비밀번호가 환경변수에 들어갑니다). 배포 로그의 `fatal` 줄에는 비밀이 섞일 수 있으니 공유 전에 검토하세요.

**실습용 단순화:** CAPO와 OCCM이 OpenStack **admin 계정**을 사용하고, 그 자격 증명이 관리 클러스터의 시크릿과 워크로드 클러스터의 `kube-system/cloud-config`에 저장됩니다. 실서비스에서는 application credential이나 최소 권한 전용 사용자를 쓰세요.

## 11. 알려진 제약

- 단일 서버, 단일 노드(all-in-one) OpenStack, 고정 3노드 토폴로지로 한정합니다. 성능과 고가용성은 다루지 않습니다.
- 호스트 재부팅 후 복구(`kolla0`, veth, 방화벽 규칙, `/dev/kvm` 접근 권한, libvirt 비활성)는 **시험하지 않았습니다.** 호스트 변경 사항은 `kolla-host-net.sh`와 systemd 유닛으로 영속화하도록 설계했지만 재부팅 검증은 남아 있습니다.
- `/dev/kvm` 사용자 ACL은 재부팅 없이도 사라집니다. 이 서버에서 ACL을 추가한 뒤 임시 VM을 만들고 지우는 동안(약 1분) 장치의 ctime이 바뀌며 사라진 것이 관찰되었습니다(VM 삭제와 시각이 일치, 원인은 확인하지 못함). ACL이 필요한 것은 사용자 프로세스가 qemu를 직접 실행하는 이미지 빌드뿐이라, 키트는 이미지가 이미 있으면 ACL을 건드리지 않고 빌드 직전에만 추가합니다.
- 클러스터 삭제 후 **같은 주문서로 재생성**하는 것을 한 번 시험했습니다(4단계 → 5단계 → 검증 a, b~e 모두 PASS). 이때 삭제 직후 OpenStack 정리 확인은 삭제 명령 종료 후 6초였습니다. 한 번의 관찰이므로 일반화하지 않습니다.
- CAPO가 Kubernetes 1.36을 공식 지원 범위에 포함하는지, ORC v2.0.3과 CAPO v0.15.1의 공식 호환은 문서로 확인하지 못했고 **동작으로만 확인**했습니다.
- 노드 VM 사양은 최소 수준입니다.
- 서비스 검증은 배포·연동 상태 중심이며 로드밸런서, Ingress, 영구 볼륨은 범위 밖입니다.
- 에러 대응은 **감지와 진단**까지입니다. 설정을 고쳐 이어서 진행하는 자동 복구는 범위 밖이며, 재시도를 넣는 경우에도 상태 확인의 반복으로 한정하고 로그에 구분해 남깁니다.

## 12. 구현 현황

| 단계 | 수동 구축 | 인계 메모 | 자동화 코드 |
| --- | --- | --- | --- |
| 0 | 완료 | 완료 | 작성됨, 이미 구축된 서버에서 점검 통과(깨끗한 서버 설치는 미시험) |
| 1 | 완료 | 완료 | 작성됨, 이미 구축된 서버에서 preflight 11 PASS, dry-run 전부 SKIP, postcheck 40 PASS 확인(깨끗한 서버의 변경 단계는 미시험) |
| 2 | 완료 | 완료 | 작성됨(apply, preflight, postcheck, verify-a). 이미 구축된 서버에서 preflight 15 PASS, dry-run SKIP, postcheck 20 PASS, 검증 a 7 PASS 확인(이미지 빌드·terraform apply 경로는 미시험) |
| 3 | 완료 | 완료 | 작성됨(apply, preflight, postcheck). 이미 구축된 서버에서 preflight 18 PASS, dry-run 전부 SKIP, postcheck 29 PASS 확인(kind 생성·clusterctl init·NAT 추가 경로는 미시험) |
| 4 | 완료 | 완료 | 작성됨(apply, preflight, postcheck, 주문서 템플릿). 이미 구축된 서버에서 preflight 20 PASS, dry-run 전부 SKIP, postcheck 18 PASS 확인(ORC 설치·Secret 생성·클러스터 생성 경로는 미시험). 삭제 뒤 같은 주문서로 재생성해 postcheck 18 PASS(노드 등록까지 약 4분, Floating IP 는 새 주소) 확인 |
| 5 | 완료 | 완료 | 작성됨(`stage5/`: apply, preflight, postcheck, verify-bcde). NotReady 상태의 실제 클러스터에서 apply 를 실행해 Calico·OCCM 설치, postcheck 17 PASS, 검증 b~e 14 PASS 확인. OCCM 을 Calico 보다 먼저 설치하는 순서로 성공함. 매니페스트 sha256 고정(수동 구축 때 받은 파일 기준). 재생성한 클러스터에서 5단계를 다시 실행해 확인 질문 응답 후 약 2분 30초에 완료, 검증 b~e 14 PASS(새 보안 그룹에는 Typha 규칙이 없어 5단계를 다시 해야 함). 새로 내려받는 경로는 미시험. **이후 `openstack`으로 직접 넣은 Typha 규칙이 CAPO 에 의해 되돌려진 것을 확인**해 규칙을 주문서(CAPO 관리 정의)로 옮겼고, 5단계 postcheck 에 정의 확인 1건을 더함(총 18). 이 수정은 새 클러스터로 시험하지 않았다 |
| 6 | 완료 | 완료 | 작성됨(`stage6/`: apply(삭제), preflight, verify-f, compare.py). 실제 서버에서 `k8s-lab` 삭제를 실행해 확인: 삭제 명령 35초, 삭제 명령 종료 후 OpenStack 정리 확인까지 6초, 검증 f 17 PASS(CAPO 서버 3·Floating IP 1·보안 그룹 2·포트 4 정리, Terraform 자원 ID 보존). 시험 중 키트 오류 2건 수정(Cinder 없는 환경의 볼륨 조회 실패, Floating IP 자체 포트의 CAPO 자원 식별). 삭제 뒤 같은 주문서로 재생성은 미시험 |

## 13. 문서

- 가이드북(RST/Sphinx, 별도 작성) — 사전 준비 → OpenStack 구축 → 공용 기반 자원 → 관리 클러스터 → 워크로드 클러스터 → Calico·OCCM → 검증·삭제 → 문제 해결 순서로 구성하며, OpenStack과 Kubernetes가 맞물리는 원리(CAPO가 OpenStack API로 VM을 만들고, OCCM이 노드와 VM 정보를 연결하는 방식)를 설명하는 절을 포함합니다.
- 가이드북의 도구 버전과 명령어는 이 README의 [고정 버전](#5-고정-버전)과 일치해야 합니다.

## 14. 라이선스와 인용

`<LICENSE 미정>` · 소속과 실명은 블라인드 심사 여부가 확인될 때까지 이 저장소에 넣지 않습니다. 제출 시점 코드에는 버전 태그를 달고 논문에 함께 적습니다.
