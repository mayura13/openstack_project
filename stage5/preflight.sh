#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0

check_pass() {
    echo "[PASS] $1"
    PASS=$((PASS + 1))
}

check_fail() {
    echo "[FAIL] $1"
    FAIL=$((FAIL + 1))
}

echo "========================================"
echo " Stage 5 - OpenStack-Helm Preflight"
echo "========================================"

# 1. kubectl
if command -v kubectl >/dev/null 2>&1; then
    check_pass "kubectl installed"
else
    check_fail "kubectl not found"
fi

# 2. Helm
if command -v helm >/dev/null 2>&1; then
    check_pass "helm installed"
else
    check_fail "helm not found"
fi

# 3. Kubernetes API
if kubectl cluster-info >/dev/null 2>&1; then
    check_pass "Kubernetes API reachable"
else
    check_fail "Kubernetes API not reachable"
fi

# 4. All Kubernetes nodes Ready
NOT_READY="$(
    kubectl get nodes --no-headers 2>/dev/null |
    awk '$2 != "Ready" {count++} END {print count+0}'
)"

if [ "$NOT_READY" -eq 0 ] && [ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)" -gt 0 ]; then
    check_pass "all Kubernetes nodes Ready"
else
    check_fail "one or more Kubernetes nodes are not Ready"
fi

# 5. openstack namespace
if kubectl get namespace openstack >/dev/null 2>&1; then
    check_pass "namespace openstack exists"
else
    check_fail "namespace openstack does not exist"
fi

# 6. StorageClass general
if kubectl get storageclass general >/dev/null 2>&1; then
    check_pass "StorageClass general exists"
else
    check_fail "StorageClass general not found"
fi

# 7. Required OpenStack node labels
LABEL_FAIL=0

kubectl get node ctrl-worker \
    -o jsonpath='{.metadata.labels.openstack-control-plane}' 2>/dev/null |
    grep -qx 'enabled' || LABEL_FAIL=1

for node in compute-1 compute-2; do
    kubectl get node "$node" \
        -o jsonpath='{.metadata.labels.openstack-compute-node}' 2>/dev/null |
        grep -qx 'enabled' || LABEL_FAIL=1
done

if [ "$LABEL_FAIL" -eq 0 ]; then
    check_pass "required OpenStack node labels configured"
else
    check_fail "required OpenStack node labels missing"
fi

# 8. Stage 5 values
VALUE_COUNT="$(
    find "${PROJECT_ROOT}/stage5/values" \
        -maxdepth 1 \
        -type f \
        -name 'values-*.yaml' 2>/dev/null |
    wc -l
)"

if [ "$VALUE_COUNT" -eq 12 ]; then
    check_pass "12 Stage 5 values files found"
else
    check_fail "expected 12 values files, found ${VALUE_COUNT}"
fi

echo
echo "========================================"
echo " Preflight result"
echo " PASS: ${PASS}"
echo " FAIL: ${FAIL}"
echo "========================================"

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
