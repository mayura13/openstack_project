#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE4_DIR="${ROOT_DIR}/stage4"

KUBESPRAY_DIR="${HOME}/kubespray"
INVENTORY_DIR="${KUBESPRAY_DIR}/inventory/openinfra"
TARGET_ADDONS="${INVENTORY_DIR}/group_vars/k8s_cluster/addons.yml"
SOURCE_ADDONS="${STAGE4_DIR}/config/addons.yml"
ANSIBLE_PLAYBOOK="${HOME}/venv-kubespray/bin/ansible-playbook"

echo "=== Stage 4 Storage Configuration ==="

# 1. Verify required files
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

sed -i \
    -e 's/^local_path_provisioner_enabled:.*/local_path_provisioner_enabled: true/' \
    -e 's/^# *local_path_provisioner_enabled:.*/local_path_provisioner_enabled: true/' \
    "${TARGET_ADDONS}"

if grep -q '^local_path_provisioner_storage_class:' "${TARGET_ADDONS}"; then
    sed -i \
        's/^local_path_provisioner_storage_class:.*/local_path_provisioner_storage_class: "general"/' \
        "${TARGET_ADDONS}"
else
    printf '\nlocal_path_provisioner_storage_class: "general"\n' >> "${TARGET_ADDONS}"
fi

# 3. Verify applied values
grep -q '^local_path_provisioner_enabled: true$' "${TARGET_ADDONS}"
grep -q '^local_path_provisioner_storage_class: "general"$' "${TARGET_ADDONS}"

echo "[PASS] Kubespray storage configuration applied"

# 4. Apply Kubespray configuration
echo
echo "[INFO] Applying Kubespray addon configuration..."

cd "${KUBESPRAY_DIR}"

"${ANSIBLE_PLAYBOOK}" \
    -i "${INVENTORY_DIR}/inventory.ini" \
    --become \
    cluster.yml

echo
echo "[PASS] Kubespray storage configuration deployed"
echo "Stage 4 storage configuration complete."
