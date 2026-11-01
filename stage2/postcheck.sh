#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE="${HOME}/venv-kubespray/bin/ansible"

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

run_check() {
    local name="$1"
    local command="$2"

    echo
    echo "[INFO] $name"

    if (
        cd "$SCRIPT_DIR"
        "$ANSIBLE" all -m shell -a "$command" -o
    ); then
        pass "$name"
    else
        fail "$name"
    fi
}

echo "========================================"
echo " Stage 2 Postcheck"
echo "========================================"

# 1. Ansible 연결
echo
echo "[INFO] Ansible connectivity"

if (
    cd "$SCRIPT_DIR"
    "$ANSIBLE" all -m ping -o
); then
    pass "Ansible connectivity"
else
    fail "Ansible connectivity"
fi

# 2. Swap 비활성화
run_check \
    "Swap is disabled" \
    'test -z "$(swapon --show --noheadings)"'

# 3. overlay 모듈
run_check \
    "overlay kernel module is loaded" \
    'grep -q "^overlay " /proc/modules'

# 4. br_netfilter 모듈
run_check \
    "br_netfilter kernel module is loaded" \
    'grep -q "^br_netfilter " /proc/modules'

# 5. IPv4 forwarding
run_check \
    "net.ipv4.ip_forward = 1" \
    'test "$(sysctl -n net.ipv4.ip_forward)" = "1"'

# 6. bridge IPv4 filtering
run_check \
    "bridge-nf-call-iptables = 1" \
    'test "$(sysctl -n net.bridge.bridge-nf-call-iptables)" = "1"'

# 7. bridge IPv6 filtering
run_check \
    "bridge-nf-call-ip6tables = 1" \
    'test "$(sysctl -n net.bridge.bridge-nf-call-ip6tables)" = "1"'

# 8. /etc/hosts에 4개 노드 등록
run_check \
    "All OpenInfra nodes exist in /etc/hosts" \
    'grep -q "^192\.168\.100\.10 cp$" /etc/hosts &&
     grep -q "^192\.168\.100\.11 ctrl-worker$" /etc/hosts &&
     grep -q "^192\.168\.100\.21 compute-1$" /etc/hosts &&
     grep -q "^192\.168\.100\.22 compute-2$" /etc/hosts'

# 9. 시간 동기화
run_check \
    "Time synchronization is active" \
    'test "$(timedatectl show -p NTPSynchronized --value)" = "yes"'

echo
echo "========================================"
echo " Result: ${PASS} PASS / ${FAIL} FAIL"
echo "========================================"

if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi

exit 0
