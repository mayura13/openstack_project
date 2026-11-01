#!/usr/bin/env bash
set -u

CONTROL_PLANE="192.168.100.10"
SSH_KEY="${HOME}/.ssh/id_vm_ed25519"
EXPECTED_VERSION="v1.35.4"

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

remote() {
    ssh \
        -i "${SSH_KEY}" \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no \
        "kit@${CONTROL_PLANE}" "$1"
}

echo "========================================"
echo " Stage 3 - Kubernetes Postcheck"
echo "========================================"

# 1. Control-plane SSH
if remote "true" >/dev/null 2>&1; then
    pass "Control-plane SSH connectivity"
else
    fail "Control-plane SSH connectivity"
fi

# 2. Kubernetes API
if remote "sudo kubectl get nodes" >/dev/null 2>&1; then
    pass "Kubernetes API reachable"
else
    fail "Kubernetes API unreachable"
fi

# 3. Node count
NODE_COUNT="$(remote "sudo kubectl get nodes --no-headers 2>/dev/null | wc -l" 2>/dev/null || echo 0)"

if [[ "${NODE_COUNT}" -eq 4 ]]; then
    pass "Kubernetes node count: 4"
else
    fail "Expected 4 nodes, found ${NODE_COUNT}"
fi

# 4. Ready nodes
READY_COUNT="$(remote "sudo kubectl get nodes --no-headers 2>/dev/null | awk '\$2 == \"Ready\" {count++} END {print count+0}'" 2>/dev/null || echo 0)"

if [[ "${READY_COUNT}" -eq 4 ]]; then
    pass "All 4 Kubernetes nodes are Ready"
else
    fail "Ready nodes: ${READY_COUNT}/4"
fi

# 5. Kubernetes version
VERSION_COUNT="$(remote "sudo kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{\"\\n\"}{end}' 2>/dev/null | grep -cx '${EXPECTED_VERSION}'" 2>/dev/null || true)"
VERSION_COUNT="${VERSION_COUNT:-0}"

if [[ "${VERSION_COUNT}" -eq 4 ]]; then
    pass "All nodes use Kubernetes ${EXPECTED_VERSION}"
else
    fail "Nodes using ${EXPECTED_VERSION}: ${VERSION_COUNT}/4"
fi

# 6. Expected node names
EXPECTED_NODES=("cp" "ctrl-worker" "compute-1" "compute-2")
MISSING_NODE=0

for node in "${EXPECTED_NODES[@]}"; do
    if ! remote "sudo kubectl get node '${node}'" >/dev/null 2>&1; then
        MISSING_NODE=1
    fi
done

if [[ "${MISSING_NODE}" -eq 0 ]]; then
    pass "Expected node names are present"
else
    fail "One or more expected nodes are missing"
fi

# 7. System pods
NOT_READY_PODS="$(remote "sudo kubectl get pods -n kube-system --no-headers 2>/dev/null | awk '\$3 != \"Running\" && \$3 != \"Completed\" {count++} END {print count+0}'" 2>/dev/null || echo 999)"

if [[ "${NOT_READY_PODS}" -eq 0 ]]; then
    pass "kube-system pods are healthy"
else
    fail "Unhealthy kube-system pods: ${NOT_READY_PODS}"
fi

# 8. Container runtime
RUNTIME_COUNT="$(remote "sudo kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.containerRuntimeVersion}{\"\\n\"}{end}' 2>/dev/null | grep -c '^containerd://'" 2>/dev/null || true)"
RUNTIME_COUNT="${RUNTIME_COUNT:-0}"

if [[ "${RUNTIME_COUNT}" -eq 4 ]]; then
    pass "All nodes use containerd"
else
    fail "Nodes using containerd: ${RUNTIME_COUNT}/4"
fi

echo
echo "========================================"
echo " Postcheck result: ${PASS} PASS / ${FAIL} FAIL"
echo "========================================"

if [[ "${FAIL}" -ne 0 ]]; then
    exit 1
fi
