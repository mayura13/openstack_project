# OpenInfra Lab Kit

OpenInfra Lab Kit는 OpenStack과 Kubernetes 기반 실습 환경을 보다 일관된 방식으로 구축하기 위한 자동화 프로젝트입니다.

기존 오픈소스 도구를 새롭게 대체하는 것이 아니라, Terraform, Ansible, Kubespray, OpenStack-Helm 등의 도구를 올바른 순서와 설정으로 연결하고, 구축 과정에서 문제가 발생했을 때 실패 단계와 원인을 쉽게 확인할 수 있도록 하는 것을 목표로 합니다.

## Project Scope

프로젝트는 다음 두 가지 인프라 구성을 대상으로 설계합니다.

1. **OpenStack on Kubernetes**
   - Bare Metal 환경에서 Kubernetes 클러스터 구축
   - Kubernetes 위에 OpenStack 배포

2. **Kubernetes on OpenStack**
   - OpenStack 위에서 Cluster API / CAPO를 이용한 Kubernetes 클러스터 구축
   - 현재는 설계 범위로 포함하며, 실제 자동화 구현은 OpenStack on Kubernetes를 중심으로 진행합니다.

## Automation Pipeline

전체 자동화 파이프라인은 다음과 같이 구성됩니다.

```text
Stage 0
Environment Check & Tool Installation
        ↓
Stage 1
Terraform + libvirt
        ↓
Stage 2
Ansible
        ↓
Stage 3
Kubespray
        ↓
Stage 4
Kubernetes / OpenStack Prerequisites
        ↓
Stage 5
OpenStack-Helm
        ↓
Stage 6
Verification
```

현재 `feature/stage0` 브랜치에서는 **Stage 0 자동화**를 구현하고 있습니다.

---

## Stage 0 - Environment Setup

Stage 0는 본격적인 인프라 구축을 시작하기 전에 Bare Metal 서버의 환경을 검사하고 필요한 도구를 설치하는 단계입니다.

Stage 0는 다음 세 단계로 구성됩니다.

```text
preflight.sh
      ↓
install.sh
      ↓
postcheck.sh
```

### 1. Preflight

`stage0/preflight.sh`

설치 전에 서버가 OpenInfra Lab Kit를 실행할 수 있는 환경인지 검사합니다.

주요 검사 항목:

- Bare Metal 환경 여부
- Ubuntu 24.04
- `/dev/kvm`
- CPU virtualization (`vmx`)
- CPU 자원
- Memory 자원
- Disk 여유 공간
- sudo 사용 가능 여부
- 외부 네트워크 / DNS
- NTP 시간 동기화

실행:

```bash
bash stage0/preflight.sh
```

검사에 실패하면 `[X]`로 표시되며 실패 원인 확인에 필요한 정보를 출력합니다.

### 2. Install

`stage0/install.sh`

Stage 0에서 필요한 기본 패키지와 도구를 설치합니다.

주요 설치 항목:

- QEMU / KVM
- libvirt
- Git / Make / Curl
- Terraform
- kubectl
- Helm
- Kubespray
- Ansible
- OpenStack CLI

실행:

```bash
bash stage0/install.sh
```

이미 필요한 버전이 설치되어 있는 경우 가능한 항목은 다시 설치하지 않고 기존 설치 상태를 확인합니다.

### 3. Post-check

`stage0/postcheck.sh`

설치 완료 후 도구와 호스트 환경이 정상적으로 준비되었는지 검사합니다.

주요 검사 항목:

- Terraform
- kubectl
- Helm
- Ansible
- OpenStack CLI
- Kubespray
- root 계정 사용 여부
- libvirt / kvm 그룹
- `/dev/kvm`
- libvirt service
- virsh 실행
- 잔여 VM 여부
- 시간 동기화

실행:

```bash
bash stage0/postcheck.sh
```

모든 검사를 통과하면 Stage 0 환경 구성이 완료된 것으로 판단합니다.

---

## Version Management

프로젝트에서 사용하는 주요 버전은 루트 디렉터리의 `versions.env`에서 관리합니다.

현재 기준 버전:

| Component | Version |
| --- | --- |
| Ubuntu | 24.04 |
| Terraform | 1.15.9 |
| kubectl | 1.35.4 |
| Kubernetes | 1.35 |
| Helm | 3.18.4 |
| ansible-core | 2.18.19 |
| Kubespray | v2.31.0 |
| libvirt Provider | 0.9.9 |
| OpenStack CLI | 10.5.0 |
| OpenStack | 2026.1 |

버전 값을 각 스크립트에 직접 작성하지 않고 가능한 경우 `versions.env`를 참조하도록 구성합니다.

---

## Repository Structure

```text
openinfra-lab-kit/
├── README.md
├── versions.env
├── common/
│   └── common.sh
├── stage0/
│   ├── preflight.sh
│   ├── install.sh
│   └── postcheck.sh
└── logs/
```

향후 Terraform, Ansible, Kubespray, OpenStack-Helm 및 검증 자동화 코드가 단계별로 추가될 예정입니다.

---

## Execution

현재 Stage 0는 다음 순서로 실행합니다.

```bash
bash stage0/preflight.sh
bash stage0/install.sh
bash stage0/postcheck.sh
```

`preflight.sh`가 실패한 경우 환경 문제를 먼저 해결한 후 설치를 진행해야 합니다.

> **Note:** Stage 0 자동화는 현재 개발 및 검증 중입니다. 기존 구축 환경에서 실행할 경우 설치된 패키지나 설정에 영향을 줄 수 있으므로 테스트 환경에서 검증 후 사용하는 것을 권장합니다.

---

## Design Principles

OpenInfra Lab Kit 자동화는 다음 원칙을 따릅니다.

- 버전과 주요 설정을 중앙에서 관리합니다.
- 각 Stage에 사전/사후 검사를 둡니다.
- 실패한 Stage와 항목을 명확하게 출력합니다.
- 가능한 경우 실패 원인을 함께 제공합니다.
- 동일한 스크립트를 다시 실행할 수 있도록 구성합니다.
- 각 Stage를 독립적으로 실행할 수 있도록 구성합니다.
- 구축 과정에서 발견한 문제와 해결 방법은 문서화합니다.

---

## Status

현재 구현 상태:

```text
Stage 0 - Environment Setup        In Progress
Stage 1 - Terraform + libvirt      Planned
Stage 2 - Ansible                  Planned
Stage 3 - Kubespray                Planned
Stage 4 - Prerequisites            Planned
Stage 5 - OpenStack-Helm           Planned
Stage 6 - Verification             Planned
```

Stage 0는 실제 수동 구축 과정에서 사용한 설치 명령과 검증 결과를 기반으로 자동화 스크립트로 전환하고 있습니다.