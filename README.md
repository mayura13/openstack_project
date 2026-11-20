# OpenInfra Lab Kit

Bare Metal 서버 한 대에서 **OpenStack과 Kubernetes 실습 환경을 일관되고 반복 가능한 방식으로 구축**하기 위한 자동화 프로젝트입니다.

새로운 클라우드 플랫폼을 만드는 것이 아니라, 기존 오픈소스 도구(Terraform, libvirt, Ansible, Kubespray, OpenStack-Helm, Kolla-Ansible, Cluster API 등)를 **올바른 순서와 설정으로 연결**합니다. 각 단계에는 사전 점검(preflight), 실행, 사후 점검(postcheck)을 두어 실패했을 때 어느 단계의 어떤 항목이 왜 실패했는지 확인할 수 있게 했습니다.

이 저장소에는 서로 반대 방향인 두 개의 키트가 있습니다.

| 폴더 | 구조 | 주요 도구 | 구현 상태 |
| --- | --- | --- | --- |
| [`openstack-on-k8s/`](openstack-on-k8s/) | Kubernetes 위에 OpenStack | Terraform + libvirt, Ansible, Kubespray, OpenStack-Helm | Stage 0~5 구현, Stage 6은 상태 수집까지. clean-state 반복 평가는 예정 |
| [`k8s-on-openstack/`](k8s-on-openstack/) | OpenStack 위에 Kubernetes | Kolla-Ansible, Terraform, image-builder, kind, Cluster API(CAPO), Calico, OCCM | Stage 0~6 스크립트 작성 완료. 일부 단계만 실제 서버에서 변경까지 시험(아래 참고) |

각 키트는 독립적으로 동작합니다. 자세한 사용법, 단계 구성, 고정 버전, 알려진 제약은 **각 폴더의 README**를 보세요.

---

## 구조

### OpenStack on Kubernetes

```text
Bare Metal
   ↓  Terraform + libvirt
Virtual Machines (4대)
   ↓  Ansible
   ↓  Kubespray
Kubernetes
   ↓  OpenStack-Helm
OpenStack
```

### Kubernetes on OpenStack

```text
Bare Metal
   ↓  Kolla-Ansible (단일 NIC 호스트, all-in-one)
OpenStack
   ↓  Terraform (공용 네트워크, flavor, 키페어, 노드 이미지)
   ↓  kind 관리 클러스터 + Cluster API + CAPO
Kubernetes 클러스터 (VM 3대: control-plane 1 + worker 2)
   ↓  Calico + OCCM
검증(a~f)과 삭제
```

## 단계 비교

두 키트는 같은 틀(Stage 0~6, preflight → 실행 → postcheck)을 씁니다. 단계의 내용은 다릅니다.

| Stage | openstack-on-k8s | k8s-on-openstack |
| --- | --- | --- |
| 0 | 환경 점검, 도구 설치 | 환경 점검, 도구 설치 |
| 1 | Terraform + libvirt로 VM 4대 | Kolla-Ansible로 OpenStack 구축 |
| 2 | Ansible 노드 사전 구성 | 노드 이미지 빌드, Terraform 공용 자원, 검증 a |
| 3 | Kubespray로 Kubernetes | kind 관리 클러스터, Cluster API |
| 4 | OpenStack-Helm 사전 구성 | CAPO로 워크로드 클러스터 생성 |
| 5 | OpenStack-Helm 배포 | Calico, OCCM, 검증 b~e |
| 6 | 상태 수집(`collect-state.sh`) | 클러스터 삭제와 검증 f |

## 시작하기

```bash
git clone <REPO_URL>
cd <REPO_DIR>/<키트 폴더>      # openstack-on-k8s 또는 k8s-on-openstack

make stage-0                   # 0단계부터 단계별로 실행
```

- `make` 명령은 **키트 폴더 안에서** 실행합니다. 루트에는 `Makefile`이 없습니다.
- 오래 걸리는 단계(이미지 빌드, OpenStack 배포 등)는 tmux 같은 별도 세션에서 실행하세요.
- 호스트 네트워크, 방화벽, 서비스를 바꾸는 단계는 실행 전에 영향과 복구 방법을 보여 주고 확인을 받습니다.

## k8s-on-openstack의 시험 범위

`k8s-on-openstack/`의 스크립트는 전부 작성되었지만, 이미 구축된 서버에서의 확인이 중심입니다.

| 상태 | 단계 |
| --- | --- |
| 실제 서버에서 변경까지 실행해 확인 | 5단계(Calico, OCCM, 검증 b~e), 6단계(클러스터 삭제, 검증 f) |
| 구축된 서버에서 읽기 전용 점검(preflight, dry-run, postcheck)으로 확인 | 0~4단계 |
| 아직 시험하지 않음 | 깨끗한 서버에서 0~4단계 변경 경로(Docker·OpenStack 배포, 이미지 빌드, kind·ORC 설치, 클러스터 생성), 삭제 후 재생성, 재부팅 후 복구 |

## 주의: 두 키트를 같은 서버에서 쓸 때

`k8s-on-openstack/`의 1단계는 Kolla의 `nova_libvirt`와 충돌하지 않도록 **호스트의 libvirt(libvirtd, virtlogd, virtlockd)를 중지**합니다. `openstack-on-k8s/`는 호스트 libvirt로 VM을 만듭니다. 그래서 두 키트를 **같은 서버에 동시에 구축할 수 없을 가능성이 큽니다**. 서버를 번갈아 쓰려면 한쪽을 정리하고 호스트를 다시 준비해야 하며, 이 전환은 시험하지 않았습니다.

## 공통 원칙

- 기존 오픈소스 도구를 대체하지 않고 연결합니다.
- 버전은 `versions.env` 한 곳에 고정하고 `latest` 태그를 쓰지 않습니다.
- 실패한 단계와 항목을 `[PASS]` / `[FAIL]`로 표시하고, 원인 후보와 조치를 함께 출력합니다.
- 각 단계를 독립적으로 실행할 수 있습니다.
- 확인한 것과 아직 시험하지 않은 것을 구분해 기록합니다.

## 비밀과 공개 규칙

이 저장소는 공개를 전제로 합니다. 아래는 저장소와 공유 로그에 넣지 않습니다(각 키트 폴더의 `.gitignore`에 등록).

- `passwords.yml`, `admin-openrc.sh`, `clouds.yaml`, kubeconfig, OCCM `cloud.conf`
- `terraform.tfstate*`, `.terraform/`, SSH 개인 키
- 실행 로그(`logs/`)와 OpenStack 자원 ID·IP가 담긴 기록 파일
- 서버 공인 IP, 계정 이름

## 라이선스

`<LICENSE 미정>`
