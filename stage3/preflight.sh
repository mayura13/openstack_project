#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBESPRAY_DIR="${HOME}/kubespray"
INVENTORY="${KUBESPRAY_DIR}/inventory/openinfra/inventory.ini"
K8S_CONFIG="${KUBESPRAY_DIR}/inventory/openinfra/group_vars/k8s_cluster/k8s-cluster.yml"
ANSIBLE="${HOME}/venv-kubespray/bin/ansible"

EXPECTED_KUBESPRAY_VERSION="v2.31.0"
EXPECTED_KUBE_VERSION="1.35.4"

PASS=0
FAIL=0

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
if [[ -d "${KUBESPRAY_DIR}/.git" ]]; then
    pass "Kubespray repository exists"
else
    fail "Kubespray repository not found"
fi

# 2. Kubespray version
ACTUAL_KUBESPRAY_VERSION="$(git -C "${KUBESPRAY_DIR}" describe --tags --always 2>/dev/null || true)"

if [[ "${ACTUAL_KUBESPRAY_VERSION}" == "${EXPECTED_KUBESPRAY_VERSION}" ]]; then
    pass "Kubespray version: ${ACTUAL_KUBESPRAY_VERSION}"
else
    fail "Kubespray version mismatch: ${ACTUAL_KUBESPRAY_VERSION}"
fi

# 3. Ansible
if [[ -x "${ANSIBLE}" ]]; then
    pass "Ansible executable exists"
else
    fail "Ansible executable not found: ${ANSIBLE}"
fi

# 4. Inventory
if [[ -f "${INVENTORY}" ]]; then
    pass "Kubespray inventory exists"
else
    fail "Kubespray inventory not found"
fi

# 5. Kubernetes configuration
if [[ -f "${K8S_CONFIG}" ]]; then
    pass "Kubernetes configuration exists"
else
    fail "Kubernetes configuration not found"
fi

# 6. Kubernetes version pin
ACTUAL_KUBE_VERSION="$(
    awk '/^[[:space:]]*kube_version:/ {print $2; exit}' "${K8S_CONFIG}" 2>/dev/null || true
)"

if [[ "${ACTUAL_KUBE_VERSION}" == "${EXPECTED_KUBE_VERSION}" ]]; then
    pass "Kubernetes version pinned: ${ACTUAL_KUBE_VERSION}"
else
    fail "Kubernetes version mismatch: ${ACTUAL_KUBE_VERSION}"
fi

# 7. Node count
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
if "${ANSIBLE}" all -i "${INVENTORY}" -m ping -o >/dev/null 2>&1; then
    pass "Ansible connectivity to all nodes"
else
    fail "Ansible connectivity failed"
fi

echo
echo "========================================"
echo " Preflight result: ${PASS} PASS / ${FAIL} FAIL"
echo "========================================"

if [[ "${FAIL}" -ne 0 ]]; then
    exit 1
fi
