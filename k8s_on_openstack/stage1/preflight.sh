#!/usr/bin/env bash
# stage1/preflight.sh — 1단계 실행 전 점검. 읽기 전용.
# 0단계 산출물이 있는지, 단일 NIC 호스트에서 1단계를 시작해도 되는 상태인지 O/X 로 판정한다.
# 이미 배포된 서버에서 실행해도 안전하다(이 경우 "이미 배포됨"을 WARN 으로 알린다).
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage1 preflight

log_info "1단계 사전 점검을 시작합니다 (로그: $KIT_LOG_FILE)"

# ---------------------------------------------------------------- 계정과 권한
if [[ "$(id -u)" -ne 0 ]]; then check_ok "root 가 아닌 일반 계정"
else check_ng "root 가 아닌 일반 계정" "일반 계정" "root" "일반 계정으로 실행해야 venv, /etc/kolla 소유권이 맞는다"; fi

if sudo_nopass; then check_ok "sudo 비밀번호 없이 사용"
else check_ng "sudo 비밀번호 없이 사용" "sudo -n true 성공" "실패" "sudoers 에 NOPASSWD 설정이 필요하다"; fi

# ---------------------------------------------------------------- 0단계 산출물

if [[ -x "$KOLLA_VENV/bin/kolla-ansible" ]]; then
  check_ok "kolla-ansible 실행 파일" "$KOLLA_VENV/bin/kolla-ansible"
else
  check_ng "kolla-ansible 실행 파일" "$KOLLA_VENV/bin/kolla-ansible" "없음" "0단계(make stage-0)가 끝나지 않았다"
fi
for f in "$KOLLA_CONFIG_DIR/globals.yml" "$KOLLA_CONFIG_DIR/passwords.yml" "$KOLLA_INVENTORY"; do
  if [[ -f "$f" ]]; then check_ok "파일 존재" "$f"
  else check_ng "파일 존재: $f" "있음" "없음" "0단계 install 의 kolla_dirs 단계가 실행되지 않았다"; fi
done

# ---------------------------------------------------------------- 호스트 네트워크 전제
if ip link show "$HOST_NIC" >/dev/null 2>&1; then check_ok "호스트 NIC" "$HOST_NIC"
else check_ng "호스트 NIC" "$HOST_NIC 있음" "없음" "versions.env 의 HOST_NIC 을 실제 인터페이스 이름으로 바꾼다(ip -br link)"; fi

if ip -4 addr show dev "$HOST_NIC" 2>/dev/null | grep -q 'inet '; then check_ok "$HOST_NIC IPv4 주소 보유"
else check_ng "$HOST_NIC IPv4 주소 보유" "IPv4 주소 있음" "없음" "호스트 NIC 에 주소가 없으면 SSH 가 끊긴다"; fi

if [[ "$(hostname)" == "localhost" ]]; then
  check_warn "호스트 이름이 localhost" "apply.sh 가 $KOLLA_HOSTNAME 으로 바꾼다"
fi

# 겹치는 대역: VIP/외부망이 호스트 NIC 대역과 겹치면 라우팅이 꼬인다
nic_cidr="$(ip -4 -o addr show dev "$HOST_NIC" 2>/dev/null | awk '{print $4}' | head -n1 || true)"
if [[ -n "$nic_cidr" ]]; then
  nic_net="${nic_cidr%.*}"
  if [[ "${KOLLA_VIP%.*}" == "$nic_net" || "${EXT_GW_CIDR%.*}" == "$nic_net" ]]; then
    check_ng "내부 대역과 호스트 대역 비충돌" "${KOLLA_VIP%.*}.0, ${EXT_GW_CIDR%.*}.0 와 달라야 함" "$nic_cidr" "versions.env 의 KOLLA_VIP, EXT_GW_CIDR 대역을 바꾼다"
  else
    check_ok "내부 대역과 호스트 대역 비충돌" "$nic_cidr"
  fi
fi

# ---------------------------------------------------------------- 인터넷(이미지 pull, docker 설치)
for t in "quay.io|https://quay.io/v2/" "download.docker.com|https://download.docker.com/linux/ubuntu/"; do
  name="${t%%|*}"; url="${t#*|}"; code="$(http_code "$url")"
  if [[ "$code" =~ ^(200|301|302|401|403)$ ]]; then check_ok "접속: $name" "HTTP $code"
  else check_ng "접속: $name" "응답 있음" "HTTP ${code:-없음}" "방화벽, DNS, 프록시 확인"; fi
done

# ---------------------------------------------------------------- 기존 상태 안내
if have_cmd docker && sudo -n docker ps --format '{{.Names}}' 2>/dev/null | grep -qx keystone; then
  check_warn "이미 배포된 서버" "apply.sh 는 prechecks/pull/deploy 를 건너뛴다. 처음부터 다시 하려면 먼저 환경을 초기화한다"
fi
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ':3306$' && ! { have_cmd docker && sudo -n docker ps --format '{{.Names}}' 2>/dev/null | grep -qx mariadb; }; then
  check_ng "3306 포트 비어 있음" "mariadb 컨테이너 외에는 미사용" "다른 프로세스가 사용 중" "호스트 mysql/mariadb 중지 필요"
fi

report_summary || die "점검 실패. 위 [FAIL] 항목을 해결한 뒤 다시 실행하세요." "$EXIT_FAIL"
log_done "1단계 사전 점검 통과"
