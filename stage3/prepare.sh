#!/usr/bin/env bash
# ==============================================================
# stage3/prepare.sh - [3단계] Kubespray 인벤토리 만들기
# ==============================================================
# Kubespray는 "inventory/sample" 폴더를 복사해서 내 환경용 인벤토리를 만들어 쓰는 것이 기본 사용법입니다.
# 이 스크립트가 하는 일
#   1) ~/kubespray 가 있고 버전이 v2.31.0 인지 확인
#   2) inventory/sample 을 ~/kubespray/inventory/openinfra 로 복사
#   3) 키트의 노드 목록(inventory.ini)과 Kubernetes 설정(k8s-cluster.yml)을 그 안에 덮어쓰기
# make stage-3 에서 preflight 다음에 실행됩니다. 여러 번 실행해도 안전합니다. (매번 새로 만듦)
# ※ 3)에서 복사하는 노드 목록(stage3/inventory/inventory.ini)은 1단계가 자동으로 만든 파일입니다.
# set -euo pipefail : 명령이 하나라도 실패하면 즉시 멈춥니다. (-e 실패 시 중단 / -u 없는 변수 사용 시 중단 / pipefail 파이프 중간 실패도 실패)
set -euo pipefail

# SCRIPT_DIR : 이 파일이 있는 폴더(stage3)의 절대 경로
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 경로 설정
#   SOURCE_INVENTORY : Kubespray가 제공하는 예제(sample) 인벤토리
#   TARGET_INVENTORY : 이 키트가 사용할 인벤토리 이름(openinfra)
KUBESPRAY_DIR="${HOME}/kubespray"
SOURCE_INVENTORY="${KUBESPRAY_DIR}/inventory/sample"
TARGET_INVENTORY="${KUBESPRAY_DIR}/inventory/openinfra"

# KIT_INVENTORY / KIT_K8S_CONFIG : 이 키트가 준비해 둔 노드 목록과 Kubernetes 설정 파일 (stage3/inventory/ 폴더)
KIT_INVENTORY="${SCRIPT_DIR}/inventory/inventory.ini"
KIT_K8S_CONFIG="${SCRIPT_DIR}/inventory/k8s-cluster.yml"

# EXPECTED_KUBESPRAY_VERSION : 기대하는 Kubespray 버전. versions.env 의 KUBESPRAY_VERSION 과 같은 값을 이곳에 직접 적었습니다.
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
# git describe --tags --always : 현재 ~/kubespray 코드가 가리키는 태그 이름
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
# 이전에 만든 openinfra 인벤토리를 지우고(rm -rf) sample에서 새로 복사합니다.
# 삭제 대상은 TARGET_INVENTORY(~/kubespray/inventory/openinfra) 하나뿐입니다.
# (이 폴더 안을 손으로 고쳤다면 사라집니다. 설정을 바꾸려면 stage3/inventory/ 의 원본 파일을 고치세요)
rm -rf "${TARGET_INVENTORY}"
# cp -a : 권한과 시간 정보까지 그대로 폴더째 복사
cp -a "${SOURCE_INVENTORY}" "${TARGET_INVENTORY}"

echo "[PASS] Kubespray sample inventory copied"

# 5. 노드 inventory 적용
# 키트의 노드 목록을 복사해 sample의 inventory.ini 를 대체합니다.
cp "${KIT_INVENTORY}" "${TARGET_INVENTORY}/inventory.ini"

# 6. Kubernetes 설정 적용
# 키트의 Kubernetes 설정 파일을 sample의 k8s-cluster.yml 자리에 복사합니다.
# sample 파일을 통째로 대체하므로, 이 파일에 없는 설정은 Kubespray의 기본값이 적용됩니다.
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
