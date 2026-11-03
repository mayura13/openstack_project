#!/usr/bin/env bash
# ==============================================================
# stage4/configure-storage.sh - [4단계] 스토리지(local-path) 설정
# ==============================================================
# OpenStack의 MariaDB, Glance 등은 데이터를 저장할 볼륨(PVC)이 필요합니다.
# 이 키트는 Ceph 같은 복잡한 스토리지 대신 노드의 로컬 디스크를 쓰는 "local-path provisioner"를 사용합니다.
# (간단하지만 데이터가 한 노드의 디스크에만 있어서 실습/연구용 구성입니다)
# 이 스크립트가 하는 일
#   1) Kubespray 설정 파일(addons.yml)에서 local-path 기능을 켜고, 스토리지클래스 이름을 "general"로 지정
#   2) Kubespray cluster.yml 을 다시 실행해서 변경을 클러스터에 적용 (시간이 꽤 걸립니다)
# 스토리지클래스 "general" 이름은 5단계 values 파일(예: values-glance.yaml)이 참조합니다.
# set -euo pipefail : 명령이 하나라도 실패하면 즉시 멈춥니다.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE4_DIR="${ROOT_DIR}/stage4"

# 경로 설정
#   TARGET_ADDONS : Kubespray 쪽 addons.yml (이 파일을 수정함)
#   SOURCE_ADDONS : 키트의 stage4/config/addons.yml (여기서는 존재 여부만 확인하고, 실제 값은 아래 sed 명령으로 넣습니다)
KUBESPRAY_DIR="${HOME}/kubespray"
INVENTORY_DIR="${KUBESPRAY_DIR}/inventory/openinfra"
TARGET_ADDONS="${INVENTORY_DIR}/group_vars/k8s_cluster/addons.yml"
SOURCE_ADDONS="${STAGE4_DIR}/config/addons.yml"
ANSIBLE_PLAYBOOK="${HOME}/venv-kubespray/bin/ansible-playbook"

echo "=== Stage 4 Storage Configuration ==="

# 1. Verify required files
# 필요한 파일과 도구가 모두 있는지 확인하고, 하나라도 없으면 중단합니다.
if [ ! -f "${SOURCE_ADDONS}" ]; then
    echo "[FAIL] Stage 4 addons configuration not found"
    exit 1
fi

if [ ! -f "${TARGET_ADDONS}" ]; then
    echo "[FAIL] Kubespray addons.yml not found"
    exit 1
fi

if [ ! -x "${ANSIBLE_PLAYBOOK}" ]; then
    echo "[FAIL] Kubespray Ansible environment not found"
    exit 1
fi

# 2. Apply Stage 4 storage settings to Kubespray addons.yml
echo "[INFO] Applying local-path provisioner configuration..."

# sed -i -e 's/찾을 패턴/바꿀 내용/' 파일 : 파일 안의 글자를 직접 바꿉니다. (-i = 파일을 그 자리에서 수정)
# 주석 처리된 줄(# local_path_provisioner_enabled: ...)이든 값이 다른 줄이든 모두 "true"로 바꿉니다.
sed -i \
    -e 's/^local_path_provisioner_enabled:.*/local_path_provisioner_enabled: true/' \
    -e 's/^# *local_path_provisioner_enabled:.*/local_path_provisioner_enabled: true/' \
    "${TARGET_ADDONS}"

# 스토리지클래스 이름 지정: 이미 설정 줄이 있으면 "general"로 바꾸고(sed), 없으면 파일 끝에 새 줄을 덧붙입니다(printf >>).
if grep -q '^local_path_provisioner_storage_class:' "${TARGET_ADDONS}"; then
    sed -i \
        's/^local_path_provisioner_storage_class:.*/local_path_provisioner_storage_class: "general"/' \
        "${TARGET_ADDONS}"
else
    printf '\nlocal_path_provisioner_storage_class: "general"\n' >> "${TARGET_ADDONS}"
fi

# 3. Verify applied values
# 적용 결과 확인. grep -q 가 실패하면(값이 의도대로 들어가지 않았으면) set -e 때문에 스크립트가 여기서 멈춥니다.
grep -q '^local_path_provisioner_enabled: true$' "${TARGET_ADDONS}"
grep -q '^local_path_provisioner_storage_class: "general"$' "${TARGET_ADDONS}"

echo "[PASS] Kubespray storage configuration applied"

# 4. Apply Kubespray configuration
echo
echo "[INFO] Applying Kubespray addon configuration..."

# Kubespray 폴더로 이동. (cluster.yml 을 이 폴더에서 실행해야 합니다)
cd "${KUBESPRAY_DIR}"

# cluster.yml 을 다시 실행해서 addons.yml 의 변경(local-path 스토리지)을 클러스터에 적용합니다. 3단계와 같은 설치 플레이북이라 시간이 걸립니다.
"${ANSIBLE_PLAYBOOK}" \
    -i "${INVENTORY_DIR}/inventory.ini" \
    --become \
    cluster.yml

echo
echo "[PASS] Kubespray storage configuration deployed"
echo "Stage 4 storage configuration complete."
