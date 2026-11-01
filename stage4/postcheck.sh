#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE4_DIR="${ROOT_DIR}/stage4"

source "${STAGE4_DIR}/chart-versions.env"

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

echo "=== Stage 4 Post-check ==="

# 1. Kubernetes access
check "Kubernetes API is reachable" \
    kubectl get nodes

# 2. OpenStack namespace
check "openstack namespace is Active" \
    bash -c '[ "$(kubectl get namespace openstack -o jsonpath="{.status.phase}" 2>/dev/null)" = "Active" ]'

# 3. ctrl-worker labels
check "ctrl-worker has OpenStack control-plane labels" \
    bash -c '[ "$(kubectl get node ctrl-worker -o jsonpath="{.metadata.labels.openstack-control-plane}" 2>/dev/null)" = "enabled" ] && [ "$(kubectl get node ctrl-worker -o jsonpath="{.metadata.labels.openvswitch}" 2>/dev/null)" = "enabled" ]'

# 4. compute-1 labels
check "compute-1 has OpenStack compute labels" \
    bash -c '[ "$(kubectl get node compute-1 -o jsonpath="{.metadata.labels.openstack-compute-node}" 2>/dev/null)" = "enabled" ] && [ "$(kubectl get node compute-1 -o jsonpath="{.metadata.labels.openvswitch}" 2>/dev/null)" = "enabled" ]'

# 5. compute-2 labels
check "compute-2 has OpenStack compute labels" \
    bash -c '[ "$(kubectl get node compute-2 -o jsonpath="{.metadata.labels.openstack-compute-node}" 2>/dev/null)" = "enabled" ] && [ "$(kubectl get node compute-2 -o jsonpath="{.metadata.labels.openvswitch}" 2>/dev/null)" = "enabled" ]'

# 6. general StorageClass
check "general StorageClass exists" \
    kubectl get storageclass general

# 7. general uses local-path
check "general uses rancher.io/local-path" \
    bash -c '[ "$(kubectl get storageclass general -o jsonpath="{.provisioner}" 2>/dev/null)" = "rancher.io/local-path" ]'

# 8. local-path provisioner is Running
check "local-path provisioner is Running" \
    bash -c 'kubectl get pods -n local-path-storage --no-headers 2>/dev/null | awk '\''$1 ~ /^local-path-provisioner-/ && $3=="Running" {found=1} END {exit !found}'\'''

# 9. OpenStack-Helm repository
check "OpenStack-Helm Helm repository exists" \
    bash -c 'helm repo list 2>/dev/null | awk '\''NR>1 && $1=="openstack-helm" && $2=="https://tarballs.opendev.org/openstack/openstack-helm" {found=1} END {exit !found}'\'''

# 10. osh plugin
check "osh Helm plugin is available" \
    bash -c 'helm plugin list 2>/dev/null | awk '\''NR>1 && $1=="osh" {found=1} END {exit !found}'\'''

# 11. OpenStack-Helm source commit
check "OpenStack-Helm source matches pinned commit" \
    bash -c '[ -d "$HOME/openstack-helm/.git" ] && [ "$(git -C "$HOME/openstack-helm" rev-parse HEAD 2>/dev/null)" = "'"${OSH_COMMIT}"'" ]'

echo
echo "Post-check result: ${PASS} PASS / ${FAIL} FAIL"

if [ "${FAIL}" -ne 0 ]; then
    exit 1
fi
