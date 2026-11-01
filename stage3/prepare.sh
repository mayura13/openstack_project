#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KUBESPRAY_DIR="${HOME}/kubespray"
SOURCE_INVENTORY="${KUBESPRAY_DIR}/inventory/sample"
TARGET_INVENTORY="${KUBESPRAY_DIR}/inventory/openinfra"

KIT_INVENTORY="${SCRIPT_DIR}/inventory/inventory.ini"
KIT_K8S_CONFIG="${SCRIPT_DIR}/inventory/k8s-cluster.yml"

EXPECTED_KUBESPRAY_VERSION="v2.31.0"

echo "========================================"
echo " Stage 3 - Prepare Kubespray Inventory"
echo "========================================"

# 1. Kubespray repository 확인
if [[ ! -d "${KUBESPRAY_DIR}/.git" ]]; then
    echo "[FAIL] Kubespray repository not found: ${KUBESPRAY_DIR}"
    exit 1
fi

echo "[PASS] Kubespray repository exists"

# 2. Kubespray 버전 확인
ACTUAL_VERSION="$(git -C "${KUBESPRAY_DIR}" describe --tags --always)"

if [[ "${ACTUAL_VERSION}" != "${EXPECTED_KUBESPRAY_VERSION}" ]]; then
    echo "[FAIL] Kubespray version mismatch"
    echo "       expected: ${EXPECTED_KUBESPRAY_VERSION}"
    echo "       actual:   ${ACTUAL_VERSION}"
    exit 1
fi

echo "[PASS] Kubespray version: ${ACTUAL_VERSION}"

# 3. 키트 설정 파일 확인
if [[ ! -f "${KIT_INVENTORY}" ]]; then
    echo "[FAIL] Missing inventory: ${KIT_INVENTORY}"
    exit 1
fi

if [[ ! -f "${KIT_K8S_CONFIG}" ]]; then
    echo "[FAIL] Missing Kubernetes config: ${KIT_K8S_CONFIG}"
    exit 1
fi

echo "[PASS] OpenInfra Lab Kit inventory exists"
echo "[PASS] OpenInfra Lab Kit Kubernetes config exists"

# 4. 기존 생성 inventory 제거 후 sample에서 다시 생성
rm -rf "${TARGET_INVENTORY}"
cp -a "${SOURCE_INVENTORY}" "${TARGET_INVENTORY}"

echo "[PASS] Kubespray sample inventory copied"

# 5. 노드 inventory 적용
cp "${KIT_INVENTORY}" "${TARGET_INVENTORY}/inventory.ini"

# 6. Kubernetes 설정 적용
cp "${KIT_K8S_CONFIG}" \
   "${TARGET_INVENTORY}/group_vars/k8s_cluster/k8s-cluster.yml"

echo "[PASS] OpenInfra inventory applied"
echo "[PASS] Kubernetes configuration applied"

echo
echo "========================================"
echo " Stage 3 inventory preparation complete"
echo "========================================"
echo "Inventory:"
echo "  ${TARGET_INVENTORY}/inventory.ini"
echo
echo "Kubernetes config:"
echo "  ${TARGET_INVENTORY}/group_vars/k8s_cluster/k8s-cluster.yml"
