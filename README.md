# OpenInfra Lab Kit

OpenInfra Lab Kit는 OpenStack과 Kubernetes 기반 실습 환경을 보다 일관되고 반복 가능한 방식으로 구축하기 위한 인프라 자동화 프로젝트입니다.

새로운 클라우드 플랫폼을 구현하는 것이 아니라, **Terraform, libvirt, Ansible, Kubespray, OpenStack-Helm** 등의 기존 오픈소스 도구를 올바른 순서와 설정으로 연결하여 Bare Metal 서버에서 OpenStack 실습 환경까지의 구축 과정을 자동화하는 것을 목표로 합니다.

각 Stage에는 가능한 경우 사전 검증(Preflight)과 사후 검증(Post-check)을 두어 구축 과정에서 문제가 발생했을 때 실패한 단계와 원인을 쉽게 확인할 수 있도록 구성했습니다.

---

## Project Scope

프로젝트는 다음 두 가지 인프라 구조를 대상으로 설계합니다.

### 1. OpenStack on Kubernetes

Bare Metal 서버 위에 가상머신을 생성하고 Kubernetes를 구축한 뒤 OpenStack-Helm을 이용하여 OpenStack을 배포합니다.

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

전체 프로젝트의 설계 범위에는 포함하지만, 현재 실제 자동화 구현과 평가는 **OpenStack on Kubernetes**를 중심으로 진행합니다.

---

# Architecture

현재 구현된 OpenStack on Kubernetes 환경은 다음과 같습니다.

```text
                         OpenInfra Lab Kit
                                │
                                ▼
                         Bare Metal Server
                                │
                       Terraform + libvirt
                                │
             ┌──────────────────┼──────────────────┐
             │                  │                  │
             ▼                  ▼                  ▼
            cp            ctrl-worker       compute-1 / 2
             │                  │                  │
             └──────────────────┼──────────────────┘
                                │
                             Ansible
                                │
                            Kubespray
                                │
                           Kubernetes
                                │
                         OpenStack-Helm
                                │
    ┌───────────────────────────┼───────────────────────────┐
    │                           │                           │
 Keystone / Glance       Nova / Neutron           Placement / etc.
                                │
                             OpenStack
```

---

# Automation Pipeline

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

현재 **Stage 0 ~ Stage 5 자동화 구현이 완료**되었습니다.

Stage 6의 상태 수집 기능까지 구현했으며, clean-state에서의 반복 구축 평가는 별도의 최종 평가 단계에서 수행할 예정입니다.

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

## 주요 검사 및 설치 항목

- Ubuntu 24.04
- `/dev/kvm`
- CPU virtualization
- CPU / Memory / Disk 자원
- sudo 사용 가능 여부
- 외부 네트워크 및 DNS
- NTP 시간 동기화
- QEMU / KVM
- libvirt
- Terraform
- kubectl
- Helm
- Kubespray
- Ansible
- OpenStack CLI

실행:

```bash
make stage-0
```

개발 환경에서의 Post-check 결과:

```text
14 PASS / 0 FAIL
```

---

# Stage 1 - Terraform + libvirt

Stage 1에서는 Terraform과 libvirt를 이용하여 Kubernetes와 OpenStack 구축에 필요한 VM과 네트워크를 생성합니다.

## VM Configuration

| Node | Role | vCPU | Memory | Disk | IP |
| --- | --- | ---: | ---: | ---: | --- |
| cp | Kubernetes Control Plane / etcd | 4 | 16 GiB | 60 GB | 192.168.100.10 |
| ctrl-worker | Worker / OpenStack Control | 16 | 32 GiB | 120 GB | 192.168.100.11 |
| compute-1 | Worker / OpenStack Compute | 10 | 32 GiB | 80 GB | 192.168.100.21 |
| compute-2 | Worker / OpenStack Compute | 10 | 32 GiB | 80 GB | 192.168.100.22 |

libvirt network:

```text
Network : openinfra-lab
Subnet  : 192.168.100.0/24
Gateway : 192.168.100.1
Mode    : NAT
```

Ubuntu 24.04 Cloud Image와 cloud-init을 이용하여 VM을 초기화하고 SSH key 기반 접근 환경을 구성합니다.

## Inventory 자동 생성

Terraform의 `node_ips` output을 이용하여 Stage 2와 Stage 3에서 사용할 inventory를 자동 생성합니다.

```text
Terraform local.nodes
        ↓
Terraform node_ips output
        ↓
common/generate-inventory.sh
        ↓
┌────────────────────────┐
│                        │
▼                        ▼
Stage 2 Inventory     Stage 3 Inventory
```

따라서 노드 IP 정보를 여러 파일에 반복해서 수동으로 작성하지 않아도 됩니다.

실행:

```bash
make stage-1
```

---

# Stage 2 - Ansible Node Preconfiguration

Stage 2에서는 Kubernetes 설치 전에 4개 노드의 운영체제 환경을 Ansible로 동일하게 구성합니다.

주요 작업:

- swap 비활성화
- `overlay` kernel module 활성화
- `br_netfilter` 활성화
- IPv4 forwarding 활성화
- bridge netfilter 설정
- `/etc/hosts` 구성
- Kubernetes 구축에 필요한 기본 패키지 설치
- NTP 상태 검증
- 노드 간 Ansible 연결 검증

`/etc/hosts`는 고정 IP를 다시 코드에 작성하지 않고 inventory의 `hostvars` 값을 이용하여 생성합니다.

```text
Terraform
   ↓
Inventory
   ↓
Ansible hostvars
   ↓
/etc/hosts
```

실행:

```bash
make stage-2
```

개발 과정에서 동일 환경에 playbook을 재실행하여 추가 설정 변경이 발생하지 않는 것도 보조적으로 확인했습니다.

이는 자동화 개발 과정의 idempotency 검증이며, 최종 결과 일관성 평가와는 별도로 구분합니다.

---

# Stage 3 - Kubespray / Kubernetes

Stage 3에서는 Kubespray를 이용하여 4개의 VM에 Kubernetes 클러스터를 구축합니다.

## Kubernetes Configuration

```yaml
kube_version: 1.35.4
kube_network_plugin: calico
container_manager: containerd
```

노드 구성:

| Node | Kubernetes Role |
| --- | --- |
| cp | control-plane / etcd |
| ctrl-worker | worker |
| compute-1 | worker |
| compute-2 | worker |

Kubespray:

```text
Version: v2.31.0
```

실행:

```bash
make stage-3
```

성공 환경에서 확인한 상태:

```text
4 / 4 nodes Ready
Kubernetes v1.35.4
CNI: Calico
Container Runtime: containerd
```

---

# Stage 4 - OpenStack-Helm Prerequisites

Stage 4에서는 Kubernetes 위에 OpenStack-Helm을 배포하기 위한 사전 환경을 구성합니다.

주요 작업:

- OpenStack-Helm source 준비
- OpenStack-Helm 버전 고정
- OpenStack 역할에 따른 Kubernetes node label 구성
- OpenStack용 storage 설정
- 배포 전 Kubernetes 상태 검증

OpenStack-Helm source:

```text
Tag    : 2026.1.0
Commit : c665eedfa3ae1b76a7e8438fffcb62aefaa30a46
```

OpenStack workload 배치는 다음과 같이 구성합니다.

```text
cp
└── Kubernetes control-plane / etcd

ctrl-worker
├── Kubernetes worker
├── OpenStack control
└── Open vSwitch

compute-1
├── Kubernetes worker
├── OpenStack compute
└── Open vSwitch

compute-2
├── Kubernetes worker
├── OpenStack compute
└── Open vSwitch
```

현재 실습 환경에서는 local-path 기반 storage를 사용합니다.

실행:

```bash
make stage-4
```

---

# Stage 5 - OpenStack-Helm Deployment

Stage 5에서는 OpenStack-Helm을 이용하여 Kubernetes 위에 OpenStack 서비스를 배포합니다.

배포 순서:

```text
RabbitMQ
   ↓
MariaDB
   ↓
Memcached
   ↓
Ingress NGINX
   ↓
Keystone
   ↓
Glance
   ↓
Open vSwitch
   ↓
libvirt
   ↓
Placement
   ↓
Nova
   ↓
Neutron
```

총 11개의 Helm release를 사용합니다.

## 주요 구성

현재 Lab 환경에 맞추어 다음과 같은 설정을 적용합니다.

- RabbitMQ / MariaDB 단일 replica
- ingress class 구성
- Glance PVC 사용
- Ceph 비활성화
- Nova QEMU virtualization 사용
- Open vSwitch 사용
- Neutron L3 HA 비활성화
- OpenStack workload node label 기반 배치

실행:

```bash
make stage-5
```

성공 환경에서 다음 항목을 확인했습니다.

- OpenStack 관련 Helm release 배포
- Keystone 서비스 및 endpoint
- Nova compute service
- Placement resource provider
- OpenStack namespace의 workload 상태

---

# Container Image Pinning

반복 구축 시 동일한 입력을 유지하기 위해 컨테이너 이미지의 가변적인 `latest-*` tag 사용을 제거했습니다.

성공한 구축 환경에서 실제 사용된 이미지 digest를 확인하고 Stage 5 values에 고정했습니다.

주요 대상:

- `kubernetes-entrypoint`
- `ceph-config-helper`
- `mariadb`
- `openvswitch`

OpenStack-Helm chart를 실제 `stage5/deploy.sh`와 동일한 chart version 및 values 조합으로 `helm template` 렌더링하여 검증했습니다.

검증 결과:

```text
[PASS] All rendered OpenStack charts use pinned images
```

이를 통해 Stage 5에서 사용하는 OpenStack workload 이미지 입력이 실행 시점의 `latest-*` 변경에 영향을 받는 것을 줄였습니다.

---

# Full Pipeline Execution

루트 `Makefile`을 이용하여 각 Stage를 독립적으로 실행할 수 있습니다.

```bash
make stage-0
make stage-1
make stage-2
make stage-3
make stage-4
make stage-5
```

전체 파이프라인:

```bash
make deploy
```

실행 흐름:

```text
make deploy
    │
    ├── stage-0
    ├── stage-1
    ├── stage-2
    ├── stage-3
    ├── stage-4
    └── stage-5
```

`make -n deploy`를 이용한 전체 명령 연결 검증을 완료했습니다.

실제 clean-state에서의 전체 반복 구축은 최종 평가 과정에서 수행합니다.

---

# Deployment Runner

전체 구축 과정의 로그와 시간을 동일한 형식으로 기록하기 위해 `run-deploy.sh`를 제공합니다.

실행 예시:

```bash
./run-deploy.sh run-01
```

각 실행은 다음과 같은 형태로 저장됩니다.

```text
logs/
└── run-01/
    ├── deploy.log
    └── timing.txt
```

`timing.txt`에는 다음 정보가 기록됩니다.

```text
run_id
start_time
end_time
duration_seconds
exit_code
```

기존 실행 결과를 실수로 덮어쓰지 않도록 동일한 run ID의 디렉터리가 존재하면 실행을 중단합니다.

---

# State Collection

반복 구축 결과의 일관성을 비교하기 위해 `evaluation/collect-state.sh`를 구현했습니다.

수집 항목:

- Kubernetes node 및 version
- Namespace별 Pod phase
- Helm release 및 chart version
- 실행 중인 container image
- OpenStack service
- OpenStack endpoint
- Nova compute service
- Placement resource provider
- Placement resource provider count

실행 예시:

```bash
./evaluation/collect-state.sh logs/run-01/final-state
```

결과 예시:

```text
final-state/
├── kubernetes-nodes.txt
├── pod-summary.txt
├── helm-releases.txt
├── container-images.txt
├── openstack-services.txt
├── openstack-endpoints.txt
├── nova-compute-services.txt
├── placement-resource-providers.txt
└── placement-resource-provider-count.txt
```

OpenStack API 상태 수집 시 Kubernetes 내부 Service DNS를 Bare Metal host에서 직접 사용하지 않고, 필요한 API에 임시 `kubectl port-forward`를 생성한 뒤 REST API를 이용하여 상태를 수집합니다.

---

# Evaluation Methodology

최종 평가는 **동일한 입력과 고정된 버전으로 clean state에서 전체 환경을 반복 구축했을 때 동일한 최종 상태가 생성되는지** 확인하는 방식으로 수행합니다.

각 회차에서 다음 상태를 수집합니다.

- Kubernetes node 목록 및 version
- Namespace별 Pod 상태 수
- Helm release 및 chart version
- OpenStack service 및 endpoint
- Nova compute service
- Placement resource provider
- 사용된 container image

실행마다 달라질 수 있는 다음 값은 비교 전에 정규화합니다.

- UUID
- timestamp
- 무작위 suffix
- 기타 실행별 비결정적 identifier

결과 일관성은 다음 형태로 보고합니다.

```text
N회 구축 중 n회 동일한 최종 상태
```

구축 소요 시간은 결과 일치 여부를 결정하는 기준으로 사용하지 않고 다음 보조 지표로 기록합니다.

```text
Average deployment time
Minimum deployment time
Maximum deployment time
```

각 반복 구축은 이전 실행에서 생성된 VM, volume, network 등의 잔여 자원이 없는 clean state에서 시작합니다.

> 현재 자동화 코드와 상태 수집 도구까지 구현된 상태이며, clean-state 반복 구축에 기반한 최종 평가는 별도의 평가 과정에서 수행할 예정입니다.

---

# Version Management

주요 버전은 코드와 환경 설정에서 고정하여 관리합니다.

| Component | Version |
| --- | --- |
| Ubuntu | 24.04 |
| Terraform | 1.15.9 |
| kubectl | 1.35.4 |
| Kubernetes | 1.35.4 |
| Helm | 3.18.4 |
| ansible-core | 2.18.19 |
| Kubespray | v2.31.0 |
| libvirt Provider | 0.9.9 |
| OpenStack CLI | 10.5.0 |
| OpenStack | 2026.1 |
| OpenStack-Helm | 2026.1.0 |

버전과 주요 설정을 고정하여 반복 구축 시 환경 차이로 발생할 수 있는 변수를 줄입니다.

---

# Repository Structure

```text
openstack_project/
├── README.md
├── Makefile
├── versions.env
├── run-deploy.sh
│
├── common/
│   ├── common.sh
│   ├── generate-inventory.py
│   └── generate-inventory.sh
│
├── stage0/
│   ├── preflight.sh
│   ├── install.sh
│   └── postcheck.sh
│
├── stage1/
│   ├── preflight.sh
│   ├── prepare.sh
│   ├── configure-apparmor.sh
│   ├── apply.sh
│   ├── postcheck.sh
│   └── terraform/
│
├── stage2/
│   ├── ansible.cfg
│   ├── inventory.ini
│   ├── prepare-nodes.yml
│   ├── preflight.sh
│   └── postcheck.sh
│
├── stage3/
│   ├── preflight.sh
│   ├── prepare.sh
│   ├── deploy.sh
│   ├── postcheck.sh
│   └── inventory/
│
├── stage4/
│   ├── prepare.sh
│   ├── configure-nodes.sh
│   ├── configure-storage.sh
│   └── postcheck.sh
│
├── stage5/
│   ├── preflight.sh
│   ├── deploy.sh
│   ├── postcheck.sh
│   └── values/
│
├── evaluation/
│   └── collect-state.sh
│
└── logs/
```

`logs/`의 실제 실행 결과는 Git에 포함하지 않도록 구성합니다.

---

# Troubleshooting Highlights

자동화 구현 과정에서 실제 수동 구축과 검증을 통해 다음과 같은 문제를 확인하고 해결했습니다.

### Kubernetes DNS

노드의 DHCP search domain 설정이 Kubernetes DNS 동작에 영향을 주는 문제를 확인하여 systemd-networkd의 `UseDomains=false` 설정을 적용했습니다.

### OpenStack-Helm Chart Version

chart version을 명시하지 않을 경우 의도하지 않은 개발 버전이 선택될 수 있어 OpenStack-Helm source와 chart version을 명시적으로 고정했습니다.

### Storage

Lab 환경에서는 Ceph를 사용하지 않고 local-path 기반 storage를 사용하도록 Glance, Nova, libvirt 관련 설정을 조정했습니다.

### Nested Virtualization

VM 기반 compute node에서 Nova instance를 실행할 수 있도록 현재 Lab 환경에서는 QEMU virtualization을 사용합니다.

### Placement API

Placement API에서 Keystone 연결 timeout이 발생한 사례를 확인했습니다. 이후 Keystone 연결이 정상화된 상태에서 Placement API Pod를 재생성하여 정상 상태로 복구했습니다.

### Evaluation Collector

Bare Metal host에서는 Kubernetes Service DNS와 ClusterIP를 직접 사용할 수 없기 때문에 OpenStack CLI만으로 서비스 상태를 수집하는 방식 대신 임시 port-forward와 OpenStack REST API를 이용하는 방식으로 변경했습니다.

### Container Image Reproducibility

OpenStack-Helm의 일부 기본 이미지가 `latest-*` tag를 사용하는 것을 확인했습니다. 성공 환경의 실제 image digest를 기준으로 Stage 5 values를 고정하고 Helm 렌더 결과에 `latest-*`가 남지 않는 것을 검증했습니다.

---

# Design Principles

OpenInfra Lab Kit는 다음 원칙을 따릅니다.

- 기존 오픈소스 도구를 대체하지 않고 연결합니다.
- 버전과 주요 설정을 명시적으로 고정합니다.
- 가능한 Stage에 사전·사후 검증을 둡니다.
- 실패한 Stage와 검사 항목을 명확하게 표시합니다.
- 각 Stage를 독립적으로 실행할 수 있도록 구성합니다.
- 동일한 입력으로 반복 가능한 구축 과정을 지향합니다.
- 구축 과정의 문제와 해결 방법을 기록합니다.
- 자동화 도구의 idempotency와 최종 결과 일관성 평가를 구분합니다.
- 평가 결과와 아직 수행하지 않은 실험을 구분하여 기록합니다.

---

# Project Status

현재 상태:

```text
Stage 0 - Environment & Tooling               Completed
Stage 1 - Terraform + libvirt                 Completed
Stage 2 - Ansible Node Preconfiguration       Completed
Stage 3 - Kubespray / Kubernetes              Completed
Stage 4 - OpenStack-Helm Prerequisites        Completed
Stage 5 - OpenStack-Helm Deployment           Completed
Stage 6 - Integrated Verification/Evaluation  Ready for Evaluation
```

추가 구현 상태:

```text
Terraform → Inventory Generation              Completed
Full Pipeline Makefile                        Completed
Deployment Runner                             Completed
Final State Collector                         Completed
Container Image Pinning                       Completed
Manual Successful Environment Baseline        Collected
Clean-state Repeated Evaluation                Pending
```

현재 성공 환경은 보존하고 있으며, 최종 반복 평가는 팀 단위 평가 일정에 맞추어 clean state에서 진행할 예정입니다.