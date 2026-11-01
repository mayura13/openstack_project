#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE="${HOME}/venv-kubespray/bin/ansible"
INVENTORY="${SCRIPT_DIR}/inventory.ini"
SSH_KEY="${HOME}/.ssh/id_vm_ed25519"

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

echo "========================================"
echo " Stage 2 Preflight Check"
echo "========================================"

# 1. Ansible 실행 파일
if [[ -x "$ANSIBLE" ]]; then
    pass "Ansible executable exists"
else
    fail "Ansible executable not found: $ANSIBLE"
fi

# 2. Ansible 버전
if [[ -x "$ANSIBLE" ]] && "$ANSIBLE" --version | head -n 1 | grep -q "core 2.18.19"; then
    pass "Ansible core version is 2.18.19"
else
    fail "Ansible core version is not 2.18.19"
fi

# 3. Inventory
if [[ -f "$INVENTORY" ]]; then
    pass "inventory.ini exists"
else
    fail "inventory.ini not found"
fi

# 4. VM SSH private key
if [[ -f "$SSH_KEY" ]]; then
    pass "VM SSH private key exists"
else
    fail "VM SSH private key not found: $SSH_KEY"
fi

# 5. 필수 노드가 inventory에 존재하는지 확인
if [[ -f "$INVENTORY" ]]; then
    MISSING_NODE=0

    for node in cp ctrl-worker compute-1 compute-2; do
        if ! grep -Eq "^${node}[[:space:]]" "$INVENTORY"; then
            echo "[FAIL] Missing node in inventory: $node"
            MISSING_NODE=1
        fi
    done

    if [[ "$MISSING_NODE" -eq 0 ]]; then
        pass "All 4 nodes exist in inventory"
    else
        FAIL=$((FAIL + 1))
    fi
fi

# 6. Ansible SSH/Python 연결
if [[ -x "$ANSIBLE" && -f "$INVENTORY" ]]; then
    echo
    echo "[INFO] Checking Ansible connectivity..."

    if (
        cd "$SCRIPT_DIR"
        "$ANSIBLE" all -m ping -o
    ); then
        pass "Ansible connectivity to all nodes"
    else
        fail "Ansible connectivity check failed"
    fi
else
    fail "Connectivity check skipped because prerequisites are missing"
fi

echo
echo "========================================"
echo " Result: ${PASS} PASS / ${FAIL} FAIL"
echo "========================================"

if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi

exit 0
