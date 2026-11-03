#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---dry-run}"

TERRAFORM_DIR="stage1/terraform"

DOMAINS=(
    "cp"
    "ctrl-worker"
    "compute-1"
    "compute-2"
)

NETWORK="openinfra-lab"
POOL="openinfra"

if [[ "$MODE" != "--dry-run" && "$MODE" != "--execute" ]]; then
    echo "Usage: $0 [--dry-run|--execute]"
    exit 1
fi

echo "========================================"
echo " OpenInfra Lab Kit - Clean State Reset"
echo "========================================"
echo
echo "Mode: $MODE"
echo

# --------------------------------------------------
# 1. Detect Terraform state
# --------------------------------------------------

echo "===== Terraform state ====="

TF_STATE="$(terraform -chdir="${TERRAFORM_DIR}" state list 2>/dev/null || true)"

if [[ -n "${TF_STATE}" ]]; then
    HAS_TF_STATE=true

    echo "[INFO] Terraform-managed resources detected:"
    echo "${TF_STATE}"
else
    HAS_TF_STATE=false

    echo "[INFO] No Terraform state found."
    echo "[INFO] Manual libvirt cleanup mode will be used."
fi

# --------------------------------------------------
# 2. Terraform-managed environment
# --------------------------------------------------

if [[ "${HAS_TF_STATE}" == true ]]; then

    if [[ "$MODE" == "--dry-run" ]]; then
        echo
        echo "===== Terraform destroy preview ====="

        terraform \
            -chdir="${TERRAFORM_DIR}" \
            plan \
            -destroy \
            -input=false

        echo
        echo "========================================"
        echo "[DRY-RUN] No resources were modified."
        echo "========================================"

        exit 0
    fi

    echo
    echo "===== Terraform destroy ====="

    terraform \
        -chdir="${TERRAFORM_DIR}" \
        destroy \
        -auto-approve \
        -input=false

    echo
    echo "========================================"
    echo "[PASS] Terraform-managed resources removed"
    echo "========================================"

    exit 0
fi

# --------------------------------------------------
# 3. Manual environment target inspection
# --------------------------------------------------

echo
echo "===== Domains targeted for removal ====="

for domain in "${DOMAINS[@]}"; do
    if virsh dominfo "$domain" >/dev/null 2>&1; then
        echo "[TARGET] domain: $domain"
    else
        echo "[SKIP] domain not found: $domain"
    fi
done

echo
echo "===== Network targeted for removal ====="

if virsh net-info "$NETWORK" >/dev/null 2>&1; then
    echo "[TARGET] network: $NETWORK"
else
    echo "[SKIP] network not found: $NETWORK"
fi

echo
echo "===== Storage pool targeted for removal ====="

if virsh pool-info "$POOL" >/dev/null 2>&1; then
    echo "[TARGET] pool: $POOL"

    echo
    echo "Volumes:"
    virsh vol-list "$POOL" || true
else
    echo "[SKIP] pool not found: $POOL"
fi

# --------------------------------------------------
# 4. Dry-run stops here
# --------------------------------------------------

if [[ "$MODE" == "--dry-run" ]]; then
    echo
    echo "========================================"
    echo "[DRY-RUN] No resources were modified."
    echo "========================================"

    exit 0
fi

# --------------------------------------------------
# 5. Manual libvirt cleanup
# --------------------------------------------------

echo
echo "===== Removing domains ====="

for domain in "${DOMAINS[@]}"; do

    if ! virsh dominfo "$domain" >/dev/null 2>&1; then
        echo "[SKIP] domain not found: $domain"
        continue
    fi

    state="$(virsh domstate "$domain" 2>/dev/null || true)"

    if [[ "$state" == "running" ]]; then
        echo "[INFO] Stopping domain: $domain"
        virsh destroy "$domain"
    fi

    echo "[INFO] Undefining domain: $domain"

    virsh undefine "$domain" --nvram 2>/dev/null \
        || virsh undefine "$domain"
done

echo
echo "===== Removing network ====="

if virsh net-info "$NETWORK" >/dev/null 2>&1; then

    if virsh net-info "$NETWORK" | grep -q "Active:.*yes"; then
        echo "[INFO] Stopping network: $NETWORK"
        virsh net-destroy "$NETWORK"
    fi

    echo "[INFO] Undefining network: $NETWORK"
    virsh net-undefine "$NETWORK"
else
    echo "[SKIP] network not found: $NETWORK"
fi

echo
echo "===== Removing storage pool ====="

if virsh pool-info "$POOL" >/dev/null 2>&1; then

    if virsh pool-info "$POOL" | grep -q "State:.*running"; then
        echo "[INFO] Stopping pool: $POOL"
        virsh pool-destroy "$POOL"
    fi

    echo "[INFO] Deleting pool contents: $POOL"
    virsh pool-delete "$POOL"

    echo "[INFO] Undefining pool: $POOL"
    virsh pool-undefine "$POOL"
else
    echo "[SKIP] pool not found: $POOL"
fi

echo
echo "========================================"
echo "[PASS] Clean-state reset completed"
echo "========================================"
