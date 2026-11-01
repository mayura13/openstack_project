#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE4_DIR="${ROOT_DIR}/stage4"

PASS=0
FAIL=0

check() {
    local name="$1"
    shift

    if "$@" >/dev/null 2>&1; then
        echo "[PASS] ${name}"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] ${name}"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Stage 4 Preflight ==="

check "kubectl is available" command -v kubectl
check "Helm is available" command -v helm

check "Kubernetes API is reachable" \
    kubectl get nodes

check "All 4 Kubernetes nodes are Ready" \
    bash -c '[ "$(kubectl get nodes --no-headers 2>/dev/null | awk '\''$2=="Ready"{n++} END{print n+0}'\'')" -eq 4 ]'

check "Kubespray repository exists" \
    test -d "${HOME}/kubespray/.git"

check "Kubespray version is v2.31.0" \
    bash -c '[ "$(git -C "$HOME/kubespray" describe --tags --exact-match 2>/dev/null)" = "v2.31.0" ]'

check "Stage 4 addon configuration exists" \
    test -f "${STAGE4_DIR}/config/addons.yml"

check "OpenStack-Helm version configuration exists" \
    test -f "${STAGE4_DIR}/chart-versions.env"

echo
echo "Preflight result: ${PASS} PASS / ${FAIL} FAIL"

if [ "${FAIL}" -ne 0 ]; then
    exit 1
fi
