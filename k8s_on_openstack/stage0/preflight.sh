#!/usr/bin/env bash
# stage0/preflight.sh — 0단계 설치 전 점검.
# 호스트가 이 키트를 돌릴 수 있는지 O/X로 판정한다. 읽기 전용이며 호스트를 바꾸지 않는다.
# 미달 항목은 "항목 / 기준값 / 실제값 / 가능한 원인"을 출력하고, 모든 항목을 본 뒤 종료 코드 1로 끝낸다.
# 이미 구축된 서버에서는 "이전 구축의 흔적"이 WARN으로만 나온다(FAIL 아님). 깨끗한 상태 확인은 check-clean-state.sh.
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage0 preflight

log_info "0단계 설치 전 점검을 시작합니다 (로그: $KIT_LOG_FILE)"

# ---------------------------------------------------------------- 1. 실행 계정
if [[ "$(id -u)" -ne 0 ]]; then
  check_ok "root 가 아닌 일반 계정으로 실행" "$(id -un)"
else
  check_ng "root 가 아닌 일반 계정으로 실행" "일반 계정" "root" \
    "venv, /etc/kolla 소유권이 root 가 되어 이후 단계가 깨진다. sudo 가능한 일반 계정으로 로그인해 다시 실행"
fi

if sudo_nopass; then
  check_ok "sudo 를 비밀번호 없이 사용 가능"
else
  check_ng "sudo 를 비밀번호 없이 사용 가능" "sudo -n true 성공" "비밀번호를 요구하거나 권한 없음" \
    "오래 걸리는 단계 중간에 sudo 가 멈춘다. 계정에 NOPASSWD 권한이 필요하다(예: /etc/sudoers.d/ 에 '<USER> ALL=(ALL) NOPASSWD:ALL', 호스트 변경이므로 직접 판단)"
fi

# ---------------------------------------------------------------- 2. 호스트 종류, OS, CPU 구조
arch="$(uname -m)"
if [[ "$arch" == "x86_64" ]]; then
  check_ok "CPU 구조 x86_64" "$arch"
else
  check_ng "CPU 구조 x86_64" "x86_64" "$arch" "내려받는 바이너리가 linux-amd64 로 고정되어 있다"
fi

if have_cmd systemd-detect-virt; then
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  if [[ "$virt" == "none" ]]; then
    check_ok "Bare Metal 서버" "systemd-detect-virt=none"
  else
    check_ng "Bare Metal 서버" "none" "${virt:-알 수 없음}" \
      "VM 위에서는 노드 VM을 KVM으로 띄우려면 중첩 가상화가 필요하다. 이 키트의 평가 범위는 Bare Metal 이다"
  fi
else
  check_ng "Bare Metal 서버" "systemd-detect-virt 사용 가능" "명령 없음" "systemd 가 없는 환경이다"
fi

# shellcheck disable=SC1091
os_id="$(. /etc/os-release 2>/dev/null && echo "${ID:-}")"
os_ver="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}")"
if [[ "$os_id" == "ubuntu" && "$os_ver" == "$UBUNTU_VERSION" ]]; then
  check_ok "Ubuntu ${UBUNTU_VERSION}" "$os_id $os_ver"
else
  check_ng "Ubuntu ${UBUNTU_VERSION}" "ubuntu $UBUNTU_VERSION" "${os_id:-?} ${os_ver:-?}" \
    "다른 OS 는 검증하지 않았다(Kolla-Ansible 22.2.0 의 지원 OS 표는 직접 확인하지 못함)"
fi

# ---------------------------------------------------------------- 3. 가상화
if [[ -c /dev/kvm ]]; then
  check_ok "/dev/kvm 존재"
else
  check_ng "/dev/kvm 존재" "문자 장치 /dev/kvm" "없음" \
    "BIOS 에서 가상화(VT-x) 비활성, 또는 kvm 모듈 미적재. 'lsmod | grep kvm' 확인. 노드 VM 테스트(검증 a)가 KVM 부팅을 요구한다"
fi

if grep -qE '\b(vmx|svm)\b' /proc/cpuinfo; then
  check_ok "CPU 가상화 플래그(vmx/svm)"
else
  check_ng "CPU 가상화 플래그(vmx/svm)" "vmx 또는 svm" "없음" "BIOS 설정 또는 가상화 환경 위에서 실행 중"
fi

# ---------------------------------------------------------------- 4. 자원 (기준값은 versions.env 의 잠정값)
threads="$(nproc)"
if [[ "$threads" -ge "$MIN_CPU_THREADS" ]]; then
  check_ok "CPU 스레드" "${threads} >= ${MIN_CPU_THREADS}"
else
  check_ng "CPU 스레드" ">= ${MIN_CPU_THREADS}" "$threads" "노드 VM 합계 12 vCPU 에 OpenStack 제어 서비스가 더해진다. 기준은 잠정값"
fi

mem="$(mem_total_gib)"
if [[ "$mem" -ge "$MIN_MEM_GIB" ]]; then
  check_ok "메모리" "${mem}GiB >= ${MIN_MEM_GIB}GiB"
else
  check_ng "메모리" ">= ${MIN_MEM_GIB}GiB" "${mem}GiB" "노드 VM 합계 24GiB 에 OpenStack 제어 서비스가 더해진다. 기준은 잠정값"
fi

for path in "$HOME" /var/lib; do
  avail="$(disk_avail_gib "$path")"
  if [[ -n "$avail" && "$avail" -ge "$MIN_DISK_GIB" ]]; then
    check_ok "디스크 여유 ($path)" "${avail}GiB >= ${MIN_DISK_GIB}GiB"
  else
    check_ng "디스크 여유 ($path)" ">= ${MIN_DISK_GIB}GiB" "${avail:-확인 불가}GiB" \
      "컨테이너 이미지, 노드 이미지 빌드(ISO 3GiB + 결과 4GiB), VM 디스크 180GB 가 들어간다. 기준은 잠정값"
  fi
done

# ---------------------------------------------------------------- 5. 시간 동기화
if have_cmd timedatectl; then
  ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  if [[ "$ntp" == "yes" ]]; then
    check_ok "NTP 시간 동기화"
  else
    check_ng "NTP 시간 동기화" "NTPSynchronized=yes" "${ntp:-확인 불가}" \
      "시간이 어긋나면 인증서·토큰 검증이 실패한다. 'timedatectl status' 로 상태 확인"
  fi
else
  check_ng "NTP 시간 동기화" "timedatectl 사용 가능" "명령 없음" "systemd 가 없는 환경이다"
fi

# ---------------------------------------------------------------- 6. 네트워크
if ! have_cmd curl; then
  check_ng "curl 설치" "curl 존재" "없음" "'sudo apt-get install -y curl' 후 다시 실행"
else
  check_ok "curl 설치"
  if getent hosts github.com >/dev/null 2>&1; then
    check_ok "DNS 조회(github.com)"
  else
    check_ng "DNS 조회(github.com)" "이름 해석 성공" "실패" "/etc/resolv.conf, 방화벽, 외부 DNS 접근 확인"
  fi
  for entry in "${KIT_NET_TARGETS[@]}"; do
    name="${entry%%|*}"; url="${entry#*|}"
    code="$(http_code "$url")"
    if [[ "$code" != "000" && -n "$code" ]]; then
      check_ok "외부 접속: $name" "HTTP $code"
    else
      check_ng "외부 접속: $name" "HTTP 응답(코드 000 아님)" "응답 없음($url)" \
        "방화벽·프록시·DNS 문제, 또는 해당 사이트 장애. 401/404 도 '응답함'으로 정상 처리한다"
    fi
  done
fi

# ---------------------------------------------------------------- 7. 이전 구축의 흔적 (WARN 만 낸다)
log_info "이전 구축의 흔적 확인 (경고만 출력합니다. 정리는 1단계에서 사용자 확인 후 진행)"
active_units=()
for u in libvirtd.service libvirtd.socket virtlogd.service virtlogd.socket virtlockd.service virtlockd.socket; do
  systemctl is-active --quiet "$u" 2>/dev/null && active_units+=("$u")
done
if [[ "${#active_units[@]}" -gt 0 ]]; then
  check_warn "호스트 libvirt 계열 유닛 실행 중" "${active_units[*]} — Kolla 의 nova_libvirt 와 충돌한다. 1단계에서 libvirtd 뿐 아니라 virtlogd/virtlockd 도 함께 중지해야 한다"
else
  check_ok "호스트 libvirt 계열 유닛 비활성"
fi

if have_cmd virsh; then
  vms="$(timeout 10 virsh -c qemu:///system list --all --name 2>/dev/null | sed '/^$/d' | tr '\n' ' ' || true)"
  nets="$(timeout 10 virsh -c qemu:///system net-list --all --name 2>/dev/null | sed '/^$/d' | tr '\n' ' ' || true)"
  [[ -n "$vms" ]]  && check_warn "libvirt VM 이 보임" "$vms — 호스트 libvirt 소켓 기준이다. Kolla 의 nova_libvirt 가 떠 있으면 같은 소켓을 쓰므로 그 안의 VM 이 보인다(이전 키트 잔재가 아닐 수 있음)"
  [[ -n "$nets" ]] && check_warn "libvirt 네트워크가 보임" "$nets (이전 키트는 ${PREV_KIT_NET_CIDR} 사용). 호스트 libvirt 소켓 기준이다. Kolla 의 nova_libvirt 가 떠 있으면 같은 소켓을 쓰므로 그 안의 VM 이 보인다(이전 키트 잔재가 아닐 수 있음)"
fi

if have_cmd ss && ss -ltn '( sport = :3306 )' 2>/dev/null | tail -n +2 | grep -q .; then
  check_warn "호스트 3306 포트 사용 중" "새 구축이면 MariaDB 가 'Address already in use' 로 실패한다. 이미 구축된 서버면 정상"
fi

report_summary || die "점검 실패. 위 [FAIL] 항목을 해결한 뒤 다시 실행하세요." "$EXIT_FAIL"
log_done "0단계 설치 전 점검 통과"
