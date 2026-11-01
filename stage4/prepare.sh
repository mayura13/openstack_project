#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE4_DIR="${ROOT_DIR}/stage4"

source "${STAGE4_DIR}/chart-versions.env"

KUBECONFIG_PATH="${HOME}/.kube/config"
OSH_DIR="${HOME}/openstack-helm"

echo "=== Stage 4 Prepare ==="

# 1. Stage 4 preflight
"${STAGE4_DIR}/preflight.sh"

# 2. Configure kubeconfig from control-plane
echo
echo "[INFO] Configuring kubeconfig..."

mkdir -p "${HOME}/.kube"

ssh \
    -i "${HOME}/.ssh/id_vm_ed25519" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    kit@192.168.100.10 \
    'sudo cat /etc/kubernetes/admin.conf' \
    > "${KUBECONFIG_PATH}"

chmod 600 "${KUBECONFIG_PATH}"

# 3. Configure OpenStack-Helm repository
echo "[INFO] Configuring OpenStack-Helm repository..."

if helm repo list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "openstack-helm"; then
    helm repo remove openstack-helm >/dev/null
fi

helm repo add \
    openstack-helm \
    https://tarballs.opendev.org/openstack/openstack-helm

helm repo update

# 4. Install osh Helm plugin when missing
echo "[INFO] Checking osh Helm plugin..."

if helm plugin list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "osh"; then
    echo "[PASS] osh plugin already installed"
else
    helm plugin install \
        https://opendev.org/openstack/openstack-helm-plugin
fi

# 5. Prepare pinned OpenStack-Helm source
echo "[INFO] Preparing OpenStack-Helm ${OSH_TAG}..."

if [ -d "${OSH_DIR}" ]; then
    if [ -d "${OSH_DIR}/.git" ]; then
        CURRENT_COMMIT="$(git -C "${OSH_DIR}" rev-parse HEAD)"

        if [ "${CURRENT_COMMIT}" = "${OSH_COMMIT}" ]; then
            echo "[PASS] OpenStack-Helm source already matches ${OSH_TAG}"
        else
            echo "[INFO] Existing source does not match pinned commit."
            rm -rf "${OSH_DIR}"
        fi
    else
        echo "[INFO] Removing non-Git OpenStack-Helm directory."
        rm -rf "${OSH_DIR}"
    fi
fi

if [ ! -d "${OSH_DIR}/.git" ]; then
    git clone \
        --branch "${OSH_TAG}" \
        --depth 1 \
        https://opendev.org/openstack/openstack-helm.git \
        "${OSH_DIR}"
fi

ACTUAL_COMMIT="$(git -C "${OSH_DIR}" rev-parse HEAD)"

if [ "${ACTUAL_COMMIT}" != "${OSH_COMMIT}" ]; then
    echo "[FAIL] OpenStack-Helm commit mismatch"
    echo "Expected: ${OSH_COMMIT}"
    echo "Actual:   ${ACTUAL_COMMIT}"
    exit 1
fi

echo
echo "[PASS] kubeconfig configured"
echo "[PASS] OpenStack-Helm repository configured"
echo "[PASS] osh plugin available"
echo "[PASS] OpenStack-Helm ${OSH_TAG} (${OSH_COMMIT}) ready"
echo
echo "Stage 4 prepare complete."
