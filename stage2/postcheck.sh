#!/usr/bin/env bash
# ==============================================================
# stage2/postcheck.sh - [2단계] 노드 설정 결과 점검
# ==============================================================
# prepare-nodes.yml 로 설정한 내용이 4대 노드 모두에 실제로 적용되었는지 확인합니다.
#   접속 / swap 꺼짐 / 커널 모듈 2개 / 네트워크 커널 설정 3개 / /etc/hosts / 시간 동기화 / DHCP 도메인 설정
# 각 확인은 Ansible의 shell 모듈로 "모든 노드에서" 명령을 실행하고, 하나라도 실패하면 그 항목은 FAIL입니다.
# make stage-2 의 마지막에 자동 실행됩니다.
# set -uo pipefail : 정의하지 않은 변수 사용/파이프 중간 실패를 오류로 취급합니다. (끝까지 점검하려고 set -e는 쓰지 않음)
set -uo pipefail

# SCRIPT_DIR : 이 파일이 있는 폴더(stage2) / ANSIBLE : 가상환경의 ansible 명령
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE="${HOME}/venv-kubespray/bin/ansible"

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

# run_check "이름" "명령" : 모든 노드에서 명령을 실행해서 성공하면 PASS, 아니면 FAIL을 출력합니다.
# ansible all -m shell -a "<명령>" -o  :  all = 모든 노드, -m shell = 쉘 명령 실행, -a = 실행할 명령, -o = 노드당 한 줄 출력
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
# swapon --show 는 켜져 있는 swap 목록을 보여 줍니다. 출력이 비어 있어야(test -z) 통과입니다.
# swap(디스크를 메모리처럼 쓰는 기능)이 켜져 있으면 Kubernetes(kubelet)가 기본 설정으로는 시작되지 않습니다.
run_check \
    "Swap is disabled" \
    'test -z "$(swapon --show --noheadings)"'

# 3. overlay 모듈
# /proc/modules 는 현재 로드된 커널 모듈 목록입니다. overlay = 컨테이너 파일시스템에 쓰이는 모듈
run_check \
    "overlay kernel module is loaded" \
    'grep -q "^overlay " /proc/modules'

# 4. br_netfilter 모듈
# br_netfilter : 브리지 네트워크 트래픽을 방화벽(iptables) 규칙이 볼 수 있게 하는 모듈 (Kubernetes 네트워킹에 필요)
run_check \
    "br_netfilter kernel module is loaded" \
    'grep -q "^br_netfilter " /proc/modules'

# 5. IPv4 forwarding
# sysctl -n 은 커널 설정값 하나를 읽습니다. ip_forward = 1 : 이 노드가 패킷을 다른 곳으로 전달할 수 있음 (Pod 통신에 필요)
run_check \
    "net.ipv4.ip_forward = 1" \
    'test "$(sysctl -n net.ipv4.ip_forward)" = "1"'

# 6. bridge IPv4 filtering
# 브리지를 지나는 IPv4 트래픽도 iptables 규칙을 적용받는지
run_check \
    "bridge-nf-call-iptables = 1" \
    'test "$(sysctl -n net.bridge.bridge-nf-call-iptables)" = "1"'

# 7. bridge IPv6 filtering
# 브리지를 지나는 IPv6 트래픽도 iptables 규칙을 적용받는지
run_check \
    "bridge-nf-call-ip6tables = 1" \
    'test "$(sysctl -n net.bridge.bridge-nf-call-ip6tables)" = "1"'

# 8. /etc/hosts에 4개 노드 등록
# /etc/hosts 에 4개 노드 이름과 IP가 등록되어 있는지 확인합니다. (노드끼리 이름으로 서로 찾을 수 있어야 함)
# 정규식의 \. 은 "점 문자 그대로"이고, ^ 와 $ 는 줄의 처음과 끝입니다. 줄 끝 && 는 "앞이 성공하면 다음 검사"입니다.
run_check \
    "All OpenInfra nodes exist in /etc/hosts" \
    'grep -q "^192\.168\.100\.10 cp$" /etc/hosts &&
     grep -q "^192\.168\.100\.11 ctrl-worker$" /etc/hosts &&
     grep -q "^192\.168\.100\.21 compute-1$" /etc/hosts &&
     grep -q "^192\.168\.100\.22 compute-2$" /etc/hosts'

# 9. 시간 동기화
# NTP 시간 동기화 상태. 노드끼리 시간이 어긋나면 인증서/클러스터 오류가 생길 수 있습니다.
run_check \
    "Time synchronization is active" \
    'test "$(timedatectl show -p NTPSynchronized --value)" = "yes"'

# 10. DHCP search domain 비활성화
# DHCP search domain 설정 파일(99-openinfra-no-dhcp-domains.network)이 만들어졌는지,
# 그 안에 Name=enp1s0 과 UseDomains=false 가 들어 있는지 확인합니다.
run_check \
    "DHCP search domain is disabled" \
    'test -f /etc/systemd/network/99-openinfra-no-dhcp-domains.network &&
     grep -q "^Name=enp1s0$" /etc/systemd/network/99-openinfra-no-dhcp-domains.network &&
     grep -q "^UseDomains=false$" /etc/systemd/network/99-openinfra-no-dhcp-domains.network'

echo
echo "========================================"
echo " Result: ${PASS} PASS / ${FAIL} FAIL"
echo "========================================"

# 실패가 하나라도 있으면 종료 코드 1로 끝납니다.
if [[ "$FAIL" -ne 0 ]]; then
    exit 1
fi

exit 0
