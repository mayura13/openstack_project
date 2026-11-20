#!/usr/bin/env bash

#지금 sudo -n true는 “비밀번호 입력 없이 sudo 가능한가?”까지 검사하는 것으로 
#실제 서버 정책이 비밀번호 sudo라면 실패할 수 있음.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 공통 함수 불러오기
source "${PROJECT_ROOT}/common/common.sh"

PASS=0
FAIL=0

print_header "OpenInfra Lab Kit - Stage 0 Preflight"


check_pass() {
    print_pass "$1"
    PASS=$((PASS + 1))
}

check_fail() {
    print_fail "$1"
    FAIL=$((FAIL + 1))
}

# 1. Bare Metal 확인
if [ "$(systemd-detect-virt 2>/dev/null)" = "none" ]; then
    check_pass "Bare Metal environment"
else
    check_fail "Bare Metal environment"
fi

# 2. Ubuntu 24.04 확인
if grep -q 'VERSION_ID="24.04"' /etc/os-release 2>/dev/null; then
    check_pass "Ubuntu 24.04"
else
    check_fail "Ubuntu 24.04"
fi

# 3. /dev/kvm 확인
if [ -c /dev/kvm ]; then
    check_pass "/dev/kvm exists"
else
    check_fail "/dev/kvm exists"
fi

# 4. Intel virtualization (vmx) 확인
if grep -q "vmx" /proc/cpuinfo 2>/dev/null; then
    check_pass "CPU virtualization (vmx)"
else
    check_fail "CPU virtualization (vmx)"
fi

# 5. CPU 확인
CPU_COUNT=$(nproc)

if [ "$CPU_COUNT" -ge 40 ]; then
    check_pass "CPU threads: $CPU_COUNT"
else
    check_fail "CPU threads: $CPU_COUNT (required >= 40)"
fi

# 6. 메모리 확인
MEM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)

if [ "$MEM_GB" -ge 112 ]; then
    check_pass "Memory: ${MEM_GB} GiB"
else
    check_fail "Memory: ${MEM_GB} GiB (required >= 112 GiB)"
fi



# 7. 디스크 여유 공간 확인
DISK_GB=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')

if [ "$DISK_GB" -ge 340 ]; then
    check_pass "Disk available: ${DISK_GB} GiB"
else
    check_fail "Disk available: ${DISK_GB} GiB (required >= 340 GiB)"
fi

# 8. sudo 사용 가능 여부 확인
if sudo -n true 2>/dev/null; then
    check_pass "sudo available"
else
    check_fail "sudo unavailable or password required"
fi

# 9. 외부 네트워크 확인
if getent hosts github.com >/dev/null 2>&1; then
    check_pass "External network / DNS"
else
    check_fail "External network / DNS"
fi

# 10. 시간 동기화 확인
if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q "yes"; then
    check_pass "NTP synchronized"
else
    check_fail "NTP synchronization"

    print_error_detail \
        "Stage 0" \
        "Time synchronization" \
        "NTP server unreachable or UDP/123 may be blocked" \
        "logs/stage0-preflight.log"

    print_info "Check with: chronyc sources"
fi

# ----------------------------------------
# Result
# ----------------------------------------

echo
echo "========================================"
echo " Preflight Result"
echo " PASS: $PASS"
echo " FAIL: $FAIL"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    echo "[X] Stage 0 preflight FAILED"
    exit 1
fi

echo "[O] Stage 0 preflight PASSED"
exit 0