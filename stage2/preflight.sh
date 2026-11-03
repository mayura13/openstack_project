#!/usr/bin/env bash
# ==============================================================
# stage2/preflight.sh - [2단계] 노드 설정(Ansible) 전 점검
# ==============================================================
# Ansible으로 4대 노드를 설정하기 전에 아래를 확인합니다.
#   Ansible 설치/버전 / 인벤토리 파일 / SSH 개인 키 / 4개 노드 이름 / 실제로 모든 노드에 접속 가능한지
# Ansible = 여러 서버에 같은 설정을 SSH로 자동 적용하는 도구입니다.
# make stage-2 가 가장 먼저 실행합니다. 아무것도 바꾸지 않아 안전합니다.
# 실패하면: [FAIL] 항목을 확인하세요. 접속 실패는 1단계(VM 생성)가 끝났는지, VM이 켜져 있는지부터 봅니다.
# set -uo pipefail
#   -u          : 정의하지 않은 변수를 쓰면 오류로 멈춥니다.
#   -o pipefail : 파이프(|) 중간 명령이 실패해도 실패로 취급합니다.
#   (set -e는 쓰지 않아서 항목이 실패해도 끝까지 점검해 결과를 모두 보여 줍니다)
set -uo pipefail

# 경로 설정
#   SCRIPT_DIR : 이 파일이 있는 폴더(stage2)의 절대 경로
#   ANSIBLE    : 0단계에서 만든 가상환경(~/venv-kubespray)의 ansible 명령
#   INVENTORY  : 1단계가 만들어 둔 인벤토리(노드 목록) 파일
#   SSH_KEY    : VM 접속용 개인 키 (1단계 prepare.sh 가 만든 것)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE="${HOME}/venv-kubespray/bin/ansible"
INVENTORY="${SCRIPT_DIR}/inventory.ini"
SSH_KEY="${HOME}/.ssh/id_vm_ed25519"

PASS=0
FAIL=0

# pass / fail : 결과를 [PASS] / [FAIL] 로 출력하고 개수를 셉니다.
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
# [[ -x 파일 ]] : 파일이 있고 실행할 수 있는지 확인합니다.
if [[ -x "$ANSIBLE" ]]; then
    pass "Ansible executable exists"
else
    fail "Ansible executable not found: $ANSIBLE"
fi

# 2. Ansible 버전
# ansible --version 의 첫 줄에 "ansible [core 2.18.19]" 같은 형태로 버전이 나옵니다.
# ※ 요구 버전 2.18.19 는 versions.env 의 ANSIBLE_CORE_VERSION 과 같은 값을 이곳에 직접 적은 것입니다.
if [[ -x "$ANSIBLE" ]] && "$ANSIBLE" --version | head -n 1 | grep -q "core 2.18.19"; then
    pass "Ansible core version is 2.18.19"
else
    fail "Ansible core version is not 2.18.19"
fi

# 3. Inventory
# 인벤토리 파일이 있는지 (1단계에서 자동 생성됩니다)
if [[ -f "$INVENTORY" ]]; then
    pass "inventory.ini exists"
else
    fail "inventory.ini not found"
fi

# 4. VM SSH private key
# VM 접속용 SSH 개인 키 파일이 있는지
if [[ -f "$SSH_KEY" ]]; then
    pass "VM SSH private key exists"
else
    fail "VM SSH private key not found: $SSH_KEY"
fi

# 5. 필수 노드가 inventory에 존재하는지 확인
if [[ -f "$INVENTORY" ]]; then
    MISSING_NODE=0

    for node in cp ctrl-worker compute-1 compute-2; do
        # 각 노드 이름으로 시작하는 줄이 인벤토리에 있는지 찾습니다. ^ 는 줄의 시작, [[:space:]] 는 공백을 뜻합니다.
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
# Ansible로 실제 접속 확인 (SSH 연결 + 대상 서버에서 파이썬 실행 가능 여부)
if [[ -x "$ANSIBLE" && -f "$INVENTORY" ]]; then
    echo
    echo "[INFO] Checking Ansible connectivity..."

    # 괄호 ( ) 안은 하위 쉘이라 그 안의 cd 는 이 줄에만 적용됩니다. (ansible.cfg 가 이 폴더에 있어서 이동해서 실행)
    # ansible all -m ping -o :
    #   all     = 인벤토리의 모든 노드        -m ping = Ansible의 ping 모듈 (네트워크 ping과 다름. 접속과 파이썬 실행을 확인)
    #   -o      = 노드당 한 줄로 간단히 출력
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

# 실패가 하나라도 있으면 종료 코드 1로 끝납니다.
if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi

exit 0
