#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$PROJECT_ROOT/stage1/terraform"
GENERATOR="$PROJECT_ROOT/common/generate-inventory.py"

STAGE2_INVENTORY="$PROJECT_ROOT/stage2/inventory.ini"
STAGE3_INVENTORY="$PROJECT_ROOT/stage3/inventory/inventory.ini"

TMP_JSON="$(mktemp)"
trap 'rm -f "$TMP_JSON"' EXIT

echo "[INFO] Reading node IPs from Terraform output..."

terraform -chdir="$TF_DIR" output -json node_ips > "$TMP_JSON"

echo "[INFO] Generating Ansible inventories..."

python3 "$GENERATOR" \
    --input "$TMP_JSON" \
    --stage2-output "$STAGE2_INVENTORY" \
    --stage3-output "$STAGE3_INVENTORY"

echo "[PASS] Inventory generation completed."
