#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---dry-run}"
TF_DIR="stage1/terraform"

if [[ "$MODE" != "--dry-run" && "$MODE" != "--execute" ]]; then
    echo "Usage: $0 [--dry-run|--execute]"
    exit 1
fi

TARGETS=(
    -target=libvirt_domain.node
    -target=libvirt_volume.node_disk
    -target=libvirt_volume.cloudinit
    -target=libvirt_cloudinit_disk.cloudinit
)

echo "========================================"
echo " OpenInfra Lab Kit - VM-only Reset"
echo "========================================"
echo "Mode: $MODE"

if [[ "$MODE" == "--dry-run" ]]; then
    terraform -chdir="$TF_DIR" plan \
        -destroy \
        -input=false \
        "${TARGETS[@]}"
    echo "[DRY-RUN] No resources were modified."
    exit 0
fi

echo "[INFO] Creating VM-only destroy plan..."

PLAN_FILE="$(mktemp -p "$PWD/stage1/terraform" vm-reset-XXXXXX.tfplan)"
trap 'rm -f "$PLAN_FILE"' EXIT

terraform -chdir="$TF_DIR" plan \
    -destroy \
    -input=false \
    "${TARGETS[@]}" \
    -out="$PLAN_FILE"


echo
echo "[INFO] Validating planned resource changes..."

terraform -chdir="$TF_DIR" show -json "$PLAN_FILE" | python3 -c '
import json
import sys

plan = json.load(sys.stdin)
changes = plan.get("resource_changes", [])

expected = {
    f"{kind}[\"{node}\"]"
    for kind in (
        "libvirt_domain.node",
        "libvirt_volume.node_disk",
        "libvirt_volume.cloudinit",
        "libvirt_cloudinit_disk.cloudinit",
    )
    for node in ("cp", "ctrl-worker", "compute-1", "compute-2")
}

destroyed = {
    change["address"]
    for change in changes
    if change["change"]["actions"] == ["delete"]
}

unexpected = [
    change["address"]
    for change in changes
    if change["change"]["actions"] not in (["delete"], ["no-op"])
]

if destroyed != expected or unexpected:
    print("[FAIL] Unexpected Terraform plan!")
    print("Missing:", sorted(expected - destroyed))
    print("Extra:", sorted(destroyed - expected))
    print("Other changes:", unexpected)
    sys.exit(1)

print("[PASS] Exactly 16 expected VM resources will be destroyed.")
'

echo
read -r -p "Type DELETE-VM-ONLY to confirm: " CONFIRM

if [[ "$CONFIRM" != "DELETE-VM-ONLY" ]]; then
    echo "[INFO] Cancelled."
    exit 1
fi

terraform -chdir="$TF_DIR" apply \
    -input=false \
    "$PLAN_FILE"

echo "[PASS] VM-only reset completed."
