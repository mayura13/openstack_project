#!/usr/bin/env bash
# ==============================================================
# stage3/preflight.sh - [3단계] Kubernetes 설치(Kubespray) 전 점검
# ==============================================================
# Kubespray = Kubernetes를 여러 서버에 자동으로 설치해 주는 Ansible 모음입니다.
# 설치를 시작하기 전에 아래 8가지를 확인합니다.
#   Kubespray 폴더 / Kubespray 버전 / Ansible / 인벤토리 / Kubernetes 설정 파일 /
#   설정에 고정된 Kubernetes 버전 / 노드 4대 / 모든 노드에 Ansible 접속
# make stage-3 의 첫 단계이며, stage3/deploy.sh 가 설치 직전에 한 번 더 실행합니다.
# 이 인벤토리와 설정 파일은 stage3/prepare.sh 가 ~/kubespray/inventory/openinfra/ 에 만들어 둔 것입니다.
# set -u : 정의하지 않은 변수를 쓰면 오류로 멈춥니다. (끝까지 점검하려고 set -e는 쓰지 않음)
set -u

# 경로 설정
#   KUBESPRAY_DIR : 0단계에서 내려받은 Kubespray 폴더(~/kubespray)
#   INVENTORY     : Kubespray가 사용할 노드 목록   K8S_CONFIG : Kubernetes 설정 파일
#   ANSIBLE       : 가상환경의 ansible 명령
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../versions.env"
KUBESPRAY_DIR="${HOME}/kubespray"
INVENTORY="${KUBESPRAY_DIR}/inventory/openinfra/inventory.ini"
K8S_CONFIG="${KUBESPRAY_DIR}/inventory/openinfra/group_vars/k8s_cluster/k8s-cluster.yml"
ANSIBLE="${HOME}/venv-kubespray/bin/ansible"

# EXPECTED_* : 이 단계에서 기대하는 버전. versions.env 의 KUBESPRAY_VERSION / Kubernetes 1.35.4 와 같은 값을
# 이곳에 직접 적어 둔 것입니다. 버전을 바꿀 때는 함께 바꿔야 합니다.
EXPECTED_KUBESPRAY_VERSION="${KUBESPRAY_VERSION}"
EXPECTED_KUBE_VERSION="${KUBERNETES_FULL_VERSION}"

PASS=0
FAIL=0

# pass / fail : 결과를 [PASS] / [FAIL] 로 출력하고 개수를 셉니다.
pass() {
    echo "[PASS] $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "[FAIL] $1"
    FAIL=$((FAIL + 1))
}

echo "========================================"
echo " Stage 3 - Kubernetes Preflight"
echo "========================================"

# 1. Kubespray repository
# ~/kubespray 폴더가 Git 저장소로 있는지 확인합니다.
if [[ -d "${KUBESPRAY_DIR}/.git" ]]; then
    pass "Kubespray repository exists"
else
    fail "Kubespray repository not found"
fi

# 2. Kubespray version
# git describe --tags --always : 현재 코드가 가리키는 태그 이름(예: v2.31.0)을 알려 줍니다. 요구 버전과 같아야 합니다.
ACTUAL_KUBESPRAY_VERSION="$(git -C "${KUBESPRAY_DIR}" describe --tags --always 2>/dev/null || true)"

if [[ "${ACTUAL_KUBESPRAY_VERSION}" == "${EXPECTED_KUBESPRAY_VERSION}" ]]; then
    pass "Kubespray version: ${ACTUAL_KUBESPRAY_VERSION}"
else
    fail "Kubespray version mismatch: ${ACTUAL_KUBESPRAY_VERSION}"
fi

# 3. Ansible
# Kubespray용 ansible 명령이 있는지
if [[ -x "${ANSIBLE}" ]]; then
    pass "Ansible executable exists"
else
    fail "Ansible executable not found: ${ANSIBLE}"
fi

# 4. Inventory
# stage3/prepare.sh 가 만들어 둔 Kubespray 인벤토리 파일이 있는지
if [[ -f "${INVENTORY}" ]]; then
    pass "Kubespray inventory exists"
else
    fail "Kubespray inventory not found"
fi

# 5. Kubernetes configuration
# Kubernetes 설정 파일(k8s-cluster.yml)이 있는지
if [[ -f "${K8S_CONFIG}" ]]; then
    pass "Kubernetes configuration exists"
else
    fail "Kubernetes configuration not found"
fi

# 6. Kubernetes version pin
# 설정 파일의 kube_version 값을 awk 로 꺼내서 1.35.4 인지 확인합니다. ($2 는 "이름: 값" 줄의 값 부분)
ACTUAL_KUBE_VERSION="$(
    awk '/^[[:space:]]*kube_version:/ {print $2; exit}' "${K8S_CONFIG}" 2>/dev/null || true
)"

if [[ "${ACTUAL_KUBE_VERSION}" == "${EXPECTED_KUBE_VERSION}" ]]; then
    pass "Kubernetes version pinned: ${ACTUAL_KUBE_VERSION}"
else
    fail "Kubernetes version mismatch: ${ACTUAL_KUBE_VERSION}"
fi

# 7. Node count
# 인벤토리에 4개 노드가 모두 있는지 줄 수를 셉니다. (wc -l 은 줄 수 세기)
NODE_COUNT="$(
    grep -E '^(cp|ctrl-worker|compute-1|compute-2)[[:space:]]' "${INVENTORY}" 2>/dev/null \
    | wc -l
)"

if [[ "${NODE_COUNT}" -eq 4 ]]; then
    pass "Inventory contains 4 nodes"
else
    fail "Expected 4 nodes, found ${NODE_COUNT}"
fi

# 8. Ansible connectivity
# Ansible로 4대 노드에 실제 접속이 되는지 확인합니다. (ping 모듈: 접속과 파이썬 실행 확인)
if "${ANSIBLE}" all -i "${INVENTORY}" -m ping -o >/dev/null 2>&1; then
    pass "Ansible connectivity to all nodes"
else
    fail "Ansible connectivity failed"
fi

echo
echo "========================================"
echo " Preflight result: ${PASS} PASS / ${FAIL} FAIL"
echo "========================================"

# 실패가 하나라도 있으면 종료 코드 1로 끝납니다.
if [[ "${FAIL}" -ne 0 ]]; then
    exit 1
fi
