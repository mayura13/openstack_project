#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/terraform"

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

check() {
    local name="$1"
    shift

    echo
    echo "[INFO] $name"

    if "$@"; then
        pass "$name"
    else
        fail "$name"
    fi
}

echo "========================================"
echo " Stage 1 Postcheck"
echo "========================================"

# 1. Terraform state
check \
    "Terraform state exists" \
    test -f "${TF_DIR}/terraform.tfstate"

# 2. Terraform output
echo
echo "[INFO] Terraform node IP output"

NODE_IPS="$(terraform -chdir="$TF_DIR" output -json node_ips 2>/dev/null || true)"

if [[ -n "$NODE_IPS" ]] &&
   grep -q '"cp"' <<< "$NODE_IPS" &&
   grep -q '"192.168.100.10"' <<< "$NODE_IPS" &&
   grep -q '"ctrl-worker"' <<< "$NODE_IPS" &&
   grep -q '"192.168.100.11"' <<< "$NODE_IPS" &&
   grep -q '"compute-1"' <<< "$NODE_IPS" &&
   grep -q '"192.168.100.21"' <<< "$NODE_IPS" &&
   grep -q '"compute-2"' <<< "$NODE_IPS" &&
   grep -q '"192.168.100.22"' <<< "$NODE_IPS"; then
    pass "Terraform node IP output"
else
    fail "Terraform node IP output"
fi

# 3. Expected domains exist
for vm in cp ctrl-worker compute-1 compute-2; do
    check \
        "Domain exists: ${vm}" \
        virsh dominfo "$vm"
done

# 4. All domains are running
for vm in cp ctrl-worker compute-1 compute-2; do
    echo
    echo "[INFO] Domain is running: ${vm}"

    STATE="$(virsh domstate "$vm" 2>/dev/null | xargs || true)"

    if [[ "$STATE" == "running" ]]; then
        pass "Domain is running: ${vm}"
    else
        fail "Domain is running: ${vm} (state=${STATE:-unknown})"
    fi
done

# 5. vCPU configuration
declare -A EXPECTED_VCPU=(
    [cp]=4
    [ctrl-worker]=16
    [compute-1]=10
    [compute-2]=10
)

for vm in cp ctrl-worker compute-1 compute-2; do
    echo
    echo "[INFO] vCPU count: ${vm}"

    ACTUAL_VCPU="$(
        virsh dominfo "$vm" 2>/dev/null |
        awk -F: '/^CPU\(s\):/ {gsub(/[[:space:]]/, "", $2); print $2}'
    )"

    if [[ "$ACTUAL_VCPU" == "${EXPECTED_VCPU[$vm]}" ]]; then
        pass "vCPU count: ${vm} = ${ACTUAL_VCPU}"
    else
        fail "vCPU count: ${vm} expected=${EXPECTED_VCPU[$vm]} actual=${ACTUAL_VCPU:-unknown}"
    fi
done

# 6. Memory configuration (virsh reports KiB)
declare -A EXPECTED_MEMORY_KIB=(
    [cp]=16777216
    [ctrl-worker]=33554432
    [compute-1]=33554432
    [compute-2]=33554432
)

for vm in cp ctrl-worker compute-1 compute-2; do
    echo
    echo "[INFO] Memory: ${vm}"

    ACTUAL_MEMORY_KIB="$(
        virsh dominfo "$vm" 2>/dev/null |
        awk -F: '/^Max memory:/ {
            gsub(/KiB/, "", $2)
            gsub(/[[:space:]]/, "", $2)
            print $2
        }'
    )"

    if [[ "$ACTUAL_MEMORY_KIB" == "${EXPECTED_MEMORY_KIB[$vm]}" ]]; then
        pass "Memory: ${vm}"
    else
        fail "Memory: ${vm} expected=${EXPECTED_MEMORY_KIB[$vm]}KiB actual=${ACTUAL_MEMORY_KIB:-unknown}KiB"
    fi
done

# 7. Libvirt network
echo
echo "[INFO] Libvirt network openinfra-lab"

NETWORK_STATE="$(virsh net-info openinfra-lab 2>/dev/null | awk '/^Active:/ {print $2}' || true)"

if [[ "$NETWORK_STATE" == "yes" ]]; then
    pass "Libvirt network openinfra-lab is active"
else
    fail "Libvirt network openinfra-lab is not active"
fi

# 8. Libvirt storage pool
echo
echo "[INFO] Libvirt storage pool openinfra"

POOL_STATE="$(virsh pool-info openinfra-lab 2>/dev/null | awk '/^State:/ {print $2}' || true)"

if [[ "$POOL_STATE" == "running" ]]; then
    pass "Libvirt storage pool openinfra is active"
else
    fail "Libvirt storage pool openinfra is not active"
fi

echo
echo "========================================"
echo " Result: ${PASS} PASS / ${FAIL} FAIL"
echo "========================================"

if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi

exit 0
