#!/usr/bin/env bash
# ==============================================================
# scripts/reset-lab.sh - 실습 환경 초기화 (VM, 가상 네트워크, 저장소 풀 삭제)
# ==============================================================
# !! 주의 !!  --execute 로 실행하면 만들어 둔 VM 4대와 그 디스크, 가상 네트워크가 삭제되며 되돌릴 수 없습니다.
#             VM 안의 Kubernetes와 OpenStack 데이터도 모두 함께 사라집니다.
#             (서버 자체와 설치한 도구(0단계), 내려받은 이미지는 지우지 않습니다)
#
# 사용법 (프로젝트 맨 위 폴더에서 실행해야 합니다. make 명령이 그렇게 실행합니다)
#   make reset-dry-run  ->  scripts/reset-lab.sh --dry-run   : 무엇이 지워질지 "보여 주기만" 함 (기본값, 안전)
#   make reset          ->  scripts/reset-lab.sh --execute   : 실제로 삭제
# 처음에는 반드시 dry-run으로 대상을 먼저 확인하세요.
#
# 동작 방식 두 가지
#   A) Terraform 상태가 있으면: terraform 이 만든 것을 terraform destroy 로 한 번에 지웁니다. (일반적인 경우)
#   B) Terraform 상태가 없으면: virsh 명령으로 이름이 정해진 VM, 네트워크, 풀만 직접 찾아서 지웁니다. (수동 정리)
#
# set -euo pipefail : 명령이 하나라도 실패하면 즉시 멈춥니다. (-e 실패 시 중단 / -u 없는 변수 사용 시 중단 / pipefail 파이프 중간 실패도 실패)
set -euo pipefail

# MODE : 첫 번째 인자(--dry-run 또는 --execute). 인자를 안 주면 --dry-run 입니다.
# ${1:---dry-run} 은 "1번째 인자가 없으면 --dry-run 사용"이라는 뜻입니다.
MODE="${1:---dry-run}"

# Terraform 코드 폴더. 프로젝트 맨 위 폴더 기준의 상대 경로이므로 다른 위치에서 실행하면 찾지 못합니다.
TERRAFORM_DIR="stage1/terraform"

# 수동 정리(B) 때 지울 VM 이름 목록. 이 4개 이름만 대상입니다.
DOMAINS=(
    "cp"
    "ctrl-worker"
    "compute-1"
    "compute-2"
)

# NETWORK / POOL : 수동 정리 때 지울 libvirt 가상 네트워크와 저장소 풀의 이름 (Terraform 코드의 이름과 같음)
NETWORK="openinfra-lab"
POOL="openinfra"

# 허용하는 모드는 --dry-run 과 --execute 두 가지뿐입니다. 그 외에는 사용법을 보여 주고 종료합니다.
if [[ "$MODE" != "--dry-run" && "$MODE" != "--execute" ]]; then
    echo "Usage: $0 [--dry-run|--execute]"
    exit 1
fi

echo "========================================"
echo " OpenInfra Lab Kit - Clean State Reset"
echo "========================================"
echo
echo "Mode: $MODE"
echo

# --------------------------------------------------
# 1. Detect Terraform state
# --------------------------------------------------

echo "===== Terraform state ====="

# terraform state list : Terraform이 관리 중인 리소스 목록. 비어 있으면 Terraform으로 만든 것이 없다는 뜻입니다. (|| true 로 실패해도 계속)
TF_STATE="$(terraform -chdir="${TERRAFORM_DIR}" state list 2>/dev/null || true)"

if [[ -n "${TF_STATE}" ]]; then
    HAS_TF_STATE=true

    echo "[INFO] Terraform-managed resources detected:"
    echo "${TF_STATE}"
else
    HAS_TF_STATE=false

    echo "[INFO] No Terraform state found."
    echo "[INFO] Manual libvirt cleanup mode will be used."
fi

# --------------------------------------------------
# 2. Terraform-managed environment
# --------------------------------------------------

# A) Terraform으로 만든 환경이 있을 때
if [[ "${HAS_TF_STATE}" == true ]]; then

    # dry-run 이면 destroy를 "미리 계산"만 하고 끝냅니다. (plan -destroy : 지울 목록만 보여 주고 실제로 지우지 않음)
    if [[ "$MODE" == "--dry-run" ]]; then
        echo
        echo "===== Terraform destroy preview ====="

        # -input=false : 중간에 질문을 하지 않고 진행합니다. (자동 실행용)
        terraform \
            -chdir="${TERRAFORM_DIR}" \
            plan \
            -destroy \
            -input=false

        echo
        echo "========================================"
        echo "[DRY-RUN] No resources were modified."
        echo "========================================"

        exit 0
    fi

    echo
    echo "===== Terraform destroy ====="

    # terraform destroy -auto-approve : 확인 질문 없이(-auto-approve) 바로 삭제합니다.
    # 이 줄이 실제로 VM, 네트워크, 디스크를 지우는 부분입니다.
    terraform \
        -chdir="${TERRAFORM_DIR}" \
        destroy \
        -auto-approve \
        -input=false

    echo
    echo "========================================"
    echo "[PASS] Terraform-managed resources removed"
    echo "========================================"

    exit 0
fi

# --------------------------------------------------
# 3. Manual environment target inspection
# --------------------------------------------------

echo
echo "===== Domains targeted for removal ====="

# B) 수동 정리: 먼저 어떤 VM이 대상인지 보여 줍니다. virsh dominfo 가 성공하면 그 이름의 VM이 있는 것입니다.
for domain in "${DOMAINS[@]}"; do
    if virsh dominfo "$domain" >/dev/null 2>&1; then
        echo "[TARGET] domain: $domain"
    else
        echo "[SKIP] domain not found: $domain"
    fi
done

echo
echo "===== Network targeted for removal ====="

if virsh net-info "$NETWORK" >/dev/null 2>&1; then
    echo "[TARGET] network: $NETWORK"
else
    echo "[SKIP] network not found: $NETWORK"
fi

echo
echo "===== Storage pool targeted for removal ====="

if virsh pool-info "$POOL" >/dev/null 2>&1; then
    echo "[TARGET] pool: $POOL"

    echo
    echo "Volumes:"
    # 풀 안에 있는 볼륨(디스크 파일) 목록을 보여 줍니다.
    virsh vol-list "$POOL" || true
else
    echo "[SKIP] pool not found: $POOL"
fi

# --------------------------------------------------
# 4. Dry-run stops here
# --------------------------------------------------

if [[ "$MODE" == "--dry-run" ]]; then
    echo
    echo "========================================"
    echo "[DRY-RUN] No resources were modified."
    echo "========================================"

    exit 0
fi

# --------------------------------------------------
# 5. Manual libvirt cleanup
# --------------------------------------------------

echo
echo "===== Removing domains ====="

# VM(libvirt 용어로 domain)을 하나씩 확인하고 삭제합니다. 이미 없는 VM은 건너뜁니다.
for domain in "${DOMAINS[@]}"; do

    if ! virsh dominfo "$domain" >/dev/null 2>&1; then
        echo "[SKIP] domain not found: $domain"
        continue
    fi

    # virsh domstate : VM의 현재 상태(running 등)
    state="$(virsh domstate "$domain" 2>/dev/null || true)"

    if [[ "$state" == "running" ]]; then
        echo "[INFO] Stopping domain: $domain"
        # ※ virsh destroy 는 이름과 달리 VM을 "삭제"하는 명령이 아니라 실행 중인 VM을 강제로 끄는(전원을 뽑는) 명령입니다.
        virsh destroy "$domain"
    fi

    echo "[INFO] Undefining domain: $domain"

    # virsh undefine : VM 정의(등록)를 삭제합니다. --nvram 옵션이 실패하는 VM이면 옵션 없이 다시 시도합니다 (|| 뒤).
    # ※ 이 명령만으로 VM 디스크 파일(qcow2)까지 삭제되지는 않습니다. 디스크는 아래 저장소 풀 정리 단계의 대상입니다.
    virsh undefine "$domain" --nvram 2>/dev/null \
        || virsh undefine "$domain"
done

echo
echo "===== Removing network ====="

if virsh net-info "$NETWORK" >/dev/null 2>&1; then

    # 가상 네트워크가 켜져 있으면(Active: yes) 먼저 끄고(net-destroy), 이어서 정의를 삭제합니다(net-undefine).
    if virsh net-info "$NETWORK" | grep -q "Active:.*yes"; then
        echo "[INFO] Stopping network: $NETWORK"
        virsh net-destroy "$NETWORK"
    fi

    echo "[INFO] Undefining network: $NETWORK"
    virsh net-undefine "$NETWORK"
else
    echo "[SKIP] network not found: $NETWORK"
fi

echo
echo "===== Removing storage pool ====="

if virsh pool-info "$POOL" >/dev/null 2>&1; then

    # 저장소 풀이 실행 중이면 먼저 중지(pool-destroy)합니다. 이것도 "삭제"가 아니라 "중지"입니다.
    if virsh pool-info "$POOL" | grep -q "State:.*running"; then
        echo "[INFO] Stopping pool: $POOL"
        virsh pool-destroy "$POOL"
    fi

    # virsh pool-delete : 저장소 풀이 가리키는 폴더(/var/lib/libvirt/images)를 삭제하려고 시도합니다. 되돌릴 수 없습니다.
    # 이어서 pool-undefine 으로 풀의 등록을 삭제합니다. (이 폴더를 다른 용도로 쓰고 있다면 dry-run 결과를 꼭 확인하세요)
    echo "[INFO] Deleting pool contents: $POOL"
    virsh pool-delete "$POOL"

    echo "[INFO] Undefining pool: $POOL"
    virsh pool-undefine "$POOL"
else
    echo "[SKIP] pool not found: $POOL"
fi

echo
echo "========================================"
echo "[PASS] Clean-state reset completed"
echo "========================================"
