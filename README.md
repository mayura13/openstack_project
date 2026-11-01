# OpenInfra Lab Kit

OpenInfra Lab Kit는 OpenStack과 Kubernetes 기반 실습 환경을 보다 일관된 방식으로 구축하기 위한 인프라 자동화 프로젝트입니다.

기존 오픈소스 도구를 새롭게 대체하는 것이 아니라, **Terraform, Ansible, Kubespray, OpenStack-Helm** 등의 도구를 올바른 순서와 설정으로 연결하여 전체 구축 과정을 단계별로 자동화하는 것을 목표로 합니다.

또한 각 Stage에 사전·사후 검증을 두어 구축 과정에서 문제가 발생했을 때 실패한 단계와 원인을 쉽게 확인할 수 있도록 구성합니다.

---

## Project Scope

프로젝트는 다음 두 가지 인프라 구성을 대상으로 설계합니다.

### 1. OpenStack on Kubernetes

Bare Metal 서버를 기반으로 다음 환경을 구축합니다.

```text
Bare Metal
    ↓
Terraform + libvirt
    ↓
Virtual Machines
    ↓
Ansible
    ↓
Kubespray
    ↓
Kubernetes
    ↓
OpenStack-Helm
    ↓
OpenStack
```

현재 OpenInfra Lab Kit의 **주요 자동화 구현 범위**입니다.

### 2. Kubernetes on OpenStack

OpenStack 위에서 Cluster API와 CAPO(Cluster API Provider OpenStack)를 이용하여 Kubernetes 클러스터를 구축하는 구조입니다.

```text
OpenStack
    ↓
Cluster API
    ↓
CAPO
    ↓
Kubernetes Cluster
```

현재 프로젝트의 설계 범위에는 포함되어 있지만, 실제 자동화 구현은 **OpenStack on Kubernetes**를 중심으로 진행합니다.

---

## Automation Pipeline

전체 자동화 파이프라인은 다음과 같습니다.

```text
Stage 0
Environment & Tooling
        ↓
Stage 1
Terraform + libvirt
        ↓
Stage 2
Ansible Node Preconfiguration
        ↓
Stage 3
Kubespray / Kubernetes
        ↓
Stage 4
OpenStack-Helm Prerequisites
        ↓
Stage 5
OpenStack-Helm Deployment
        ↓
Stage 6
Integrated Verification & Evaluation
```

현재 **Stage 0 ~ Stage 3 자동화 구현이 완료**되었습니다.

---

# Stage 0 - Environment & Tooling

Stage 0는 본격적인 인프라 구축 전에 Bare Metal 서버의 환경을 검사하고 필요한 도구를 준비하는 단계입니다.

```text
preflight.sh
    ↓
install.sh
    ↓
postcheck.sh
```

## Preflight

`stage0/preflight.sh`

주요 검사 항목:

- Bare Metal 환경
- Ubuntu 24.04
- `/dev/kvm`
- CPU virtualization
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

## Install

`stage0/install.sh`

주요 설치 및 준비 항목:

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

## Post-check

`stage0/postcheck.sh`

설치 후 도구 버전과 호스트 환경을 검증합니다.

실행:

```bash
bash stage0/postcheck.sh
```

현재 검증 결과:

```text
14 PASS / 0 FAIL
```

---

# Stage 1 - Terraform + libvirt

Stage 1에서는 Terraform과 libvirt를 이용하여 Kubernetes 및 OpenStack 구축에 필요한 가상머신과 네트워크를 생성합니다.

구성:

```text
stage1/
├── preflight.sh
├── prepare.sh
├── configure-apparmor.sh
├── apply.sh
├── postcheck.sh
└── terraform/
    ├── versions.tf
    ├── main.tf
    └── .terraform.lock.hcl
```

## Infrastructure

생성되는 VM은 다음과 같습니다.

| Node | Role | vCPU | Memory | Disk | IP |
| --- | --- | ---: | ---: | ---: | --- |
| cp | Kubernetes Control Plane / etcd | 4 | 16 GiB | 60 GB | 192.168.100.10 |
| ctrl-worker | Worker / OpenStack Control | 16 | 32 GiB | 120 GB | 192.168.100.11 |
| compute-1 | Worker / Compute | 10 | 32 GiB | 80 GB | 192.168.100.21 |
| compute-2 | Worker / Compute | 10 | 32 GiB | 80 GB | 192.168.100.22 |

libvirt 네트워크:

```text
Network : openinfra-lab
Subnet  : 192.168.100.0/24
Gateway : 192.168.100.1
Mode    : NAT
```

고정 MAC 주소와 DHCP reservation을 이용하여 각 VM에 동일한 IP가 할당되도록 구성합니다.

Ubuntu 24.04 Cloud Image를 기반으로 VM을 생성하며, cloud-init을 이용해 초기 사용자와 SSH 접근 환경을 설정합니다.

---

# Stage 2 - Ansible Node Preconfiguration

Stage 2에서는 Kubernetes 설치 전에 4개 노드의 운영체제 환경을 Ansible로 동일하게 구성합니다.

구성:

```text
stage2/
├── ansible.cfg
├── inventory.ini
├── prepare-nodes.yml
├── preflight.sh
└── postcheck.sh
```

주요 작업:

- swap 비활성화
- `overlay` kernel module 활성화
- `br_netfilter` kernel module 활성화
- IPv4 forwarding 활성화
- bridge netfilter 설정
- `/etc/hosts` 노드 정보 구성
- Kubernetes 구축에 필요한 기본 패키지 설치
- 노드 간 Ansible 연결 검증
- NTP 동기화 상태 검증

실행 예시:

```bash
~/venv-kubespray/bin/ansible-playbook \
    -i stage2/inventory.ini \
    stage2/prepare-nodes.yml
```

현재 사전·사후 검증 결과:

```text
Preflight  : 6 PASS / 0 FAIL
Post-check : 9 PASS / 0 FAIL
```

동일 환경에서 playbook을 재실행했을 때 추가 설정 변경이 발생하지 않는 것도 개발 과정의 보조 검증으로 확인했습니다.

---

# Stage 3 - Kubespray / Kubernetes

Stage 3에서는 Kubespray를 이용하여 Stage 1과 Stage 2에서 준비한 4개 노드에 Kubernetes 클러스터를 구축합니다.

구성:

```text
stage3/
├── preflight.sh
├── prepare.sh
├── deploy.sh
├── postcheck.sh
└── inventory/
    ├── inventory.ini
    └── k8s-cluster.yml
```

## Kubernetes Configuration

현재 고정된 주요 설정:

```yaml
kube_version: 1.35.4
kube_network_plugin: calico
container_manager: containerd
```

노드 역할:

| Node | Kubernetes Role |
| --- | --- |
| cp | control-plane / etcd |
| ctrl-worker | worker |
| compute-1 | worker |
| compute-2 | worker |

## Prepare

`stage3/prepare.sh`는 Kubespray `v2.31.0`의 sample inventory를 기반으로 OpenInfra Lab Kit용 inventory를 생성합니다.

```bash
./stage3/prepare.sh
```

## Preflight

배포 전에 다음 항목을 검사합니다.

- Kubespray repository
- Kubespray version
- Ansible 실행 환경
- inventory
- Kubernetes configuration
- Kubernetes version pin
- 4개 노드 구성
- Ansible connectivity

```bash
./stage3/preflight.sh
```

현재 결과:

```text
8 PASS / 0 FAIL
```

## Deploy

`stage3/deploy.sh`는 Kubespray의 `cluster.yml`을 이용하여 Kubernetes를 구축합니다.

```bash
./stage3/deploy.sh
```

배포 과정의 출력은 `logs/`에 저장하며 구축 소요 시간도 함께 기록합니다.

현재 개발 서버에는 수동 구축 과정에서 이미 정상 Kubernetes 클러스터가 구성되어 있기 때문에 기존 환경을 보존하기 위해 자동화된 `deploy.sh`를 다시 실행하지 않았습니다.

전체 clean-state 배포는 최종 반복 구축 평가 과정에서 검증합니다.

## Post-check

배포 후 다음 항목을 검사합니다.

- control-plane SSH 연결
- Kubernetes API
- 노드 수
- 전체 노드 Ready 상태
- Kubernetes 버전
- 예상 노드 이름
- kube-system Pod 상태
- container runtime

```bash
./stage3/postcheck.sh
```

현재 결과:

```text
8 PASS / 0 FAIL
```

현재 클러스터 상태:

```text
4 / 4 nodes Ready
Kubernetes v1.35.4
CNI: Calico
Container Runtime: containerd
```

---

# Version Management

프로젝트의 주요 버전은 루트 디렉터리의 `versions.env`에서 관리합니다.

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

버전과 주요 설정을 고정하여 반복 구축 시 환경 차이로 발생할 수 있는 변수를 줄이는 것을 목표로 합니다.

---

# Repository Structure

현재 주요 디렉터리 구조는 다음과 같습니다.

```text
openstack_project/
├── README.md
├── versions.env
├── Makefile
├── common/
│   └── common.sh
├── stage0/
│   ├── preflight.sh
│   ├── install.sh
│   └── postcheck.sh
├── stage1/
│   ├── preflight.sh
│   ├── prepare.sh
│   ├── configure-apparmor.sh
│   ├── apply.sh
│   ├── postcheck.sh
│   └── terraform/
├── stage2/
│   ├── ansible.cfg
│   ├── inventory.ini
│   ├── prepare-nodes.yml
│   ├── preflight.sh
│   └── postcheck.sh
├── stage3/
│   ├── preflight.sh
│   ├── prepare.sh
│   ├── deploy.sh
│   ├── postcheck.sh
│   └── inventory/
└── logs/
```

Stage 4 이후 OpenStack-Helm 구성 및 통합 검증 코드가 추가될 예정입니다.

---

# Execution Flow

현재 구현된 자동화 흐름은 다음과 같습니다.

```text
Stage 0
Environment / Tooling
        ↓
Stage 1
VM & Network Provisioning
        ↓
Stage 2
Node Preconfiguration
        ↓
Stage 3
Kubernetes Deployment
```

각 Stage는 가능한 경우 다음 구조를 따릅니다.

```text
Preflight
    ↓
Prepare / Deploy
    ↓
Post-check
```

이를 통해 각 Stage를 독립적으로 검증하고 실패 위치를 명확하게 확인할 수 있도록 구성합니다.

---

# Evaluation

최종 평가는 동일한 입력과 고정된 버전을 이용하여 전체 환경을 clean state에서 반복 구축했을 때 **동일한 최종 상태가 생성되는지** 확인하는 방식으로 수행합니다.

각 반복 구축에서는 다음과 같은 결과를 수집할 예정입니다.

- Kubernetes 노드 목록 및 버전
- Namespace별 Pod 상태
- Helm release 및 chart version
- OpenStack 서비스 및 endpoint
- Nova compute service 상태
- Placement resource provider
- 사용된 container image tag

UUID, timestamp, 무작위 suffix 등 실행마다 달라질 수 있는 값은 정규화한 뒤 첫 번째 구축 결과와 비교합니다.

결과 일관성은 다음과 같은 형태로 보고합니다.

```text
N회 구축 중 n회 동일한 최종 상태
```

구축 소요 시간은 결과 일치 여부의 판정 기준으로 사용하지 않고 평균, 최소, 최대 시간을 보조 지표로 기록합니다.

각 반복 구축은 이전 실행의 VM, volume, network 등 잔여 자원이 없는 clean state에서 시작합니다.

---

# Design Principles

OpenInfra Lab Kit는 다음 원칙을 따릅니다.

- 버전과 주요 설정을 고정하고 관리합니다.
- 각 Stage에 사전·사후 검증을 둡니다.
- 실패한 Stage와 검사 항목을 명확하게 출력합니다.
- 가능한 경우 실패 원인을 함께 제공합니다.
- 각 Stage를 독립적으로 실행할 수 있도록 구성합니다.
- 반복 가능한 인프라 구축 과정을 지향합니다.
- 구축 과정에서 발견한 문제와 해결 방법을 문서화합니다.
- 자동화 도구 자체와 최종 결과 일관성 평가를 구분합니다.

---

# Project Status

현재 구현 상태:

```text
Stage 0 - Environment & Tooling              Completed
Stage 1 - Terraform + libvirt                Completed
Stage 2 - Ansible Node Preconfiguration      Completed
Stage 3 - Kubespray / Kubernetes             Completed
Stage 4 - OpenStack-Helm Prerequisites       Planned
Stage 5 - OpenStack-Helm Deployment          Planned
Stage 6 - Integrated Verification/Evaluation Planned
```

현재까지 Bare Metal 환경 점검부터 VM 생성, 노드 사전 설정, Kubernetes 클러스터 구축까지의 자동화 코드를 구현했습니다.

다음 단계에서는 Kubernetes 환경을 OpenStack-Helm 배포에 적합하도록 준비하는 **Stage 4 - OpenStack-Helm Prerequisites**를 구현합니다.