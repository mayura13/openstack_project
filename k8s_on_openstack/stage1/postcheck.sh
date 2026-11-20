#!/usr/bin/env bash
# stage1/postcheck.sh — 1단계 완료 후 점검. 읽기 전용.
# 산출물: 호스트 네트워크(서비스, 인터페이스, NAT), 호스트 이름, globals.yml 값, Docker, Kolla 컨테이너와 이미지,
#         admin-openrc.sh / clouds.yaml, OpenStack 서비스 목록. 비밀번호 값은 출력하지 않는다.
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage1 postcheck
use_kolla_venv

GLOBALS="$KOLLA_CONFIG_DIR/globals.yml"
log_info "1단계 사후 점검을 시작합니다 (로그: $KIT_LOG_FILE)"

gv() { { grep -E "^$1:" "$GLOBALS" 2>/dev/null | head -n1 | sed -E 's/^[^:]+:[[:space:]]*//; s/[[:space:]]+$//; s/^"//; s/"$//'; } || true; }
sd() { sudo -n docker "$@" 2>/dev/null || true; }

# ---------------------------------------------------------------- 호스트 네트워크
for f in "$HOST_NET_SCRIPT" "$HOST_NET_UNIT" "$HOST_NET_SYSCTL"; do
  if [[ -f "$f" ]]; then check_ok "파일 존재" "$f"; else check_ng "파일 존재: $f" "있음" "없음" "apply.sh 의 host_net 단계 미실행"; fi
done
if systemctl is-enabled --quiet kolla-host-net.service 2>/dev/null && systemctl is-active --quiet kolla-host-net.service 2>/dev/null; then
  check_ok "kolla-host-net.service enabled, active"
else
  check_ng "kolla-host-net.service enabled, active" "enabled, active" "$(systemctl is-enabled kolla-host-net.service 2>&1 || true) / $(systemctl is-active kolla-host-net.service 2>&1 || true)" "재부팅 뒤 네트워크가 복구되지 않는다. apply.sh 재실행"
fi
if ip -4 addr show dev "$KOLLA_NET_IF" 2>/dev/null | grep -q "inet ${KOLLA_VIP}/"; then check_ok "$KOLLA_NET_IF 에 VIP" "$KOLLA_VIP"
else check_ng "$KOLLA_NET_IF 에 VIP" "$KOLLA_VIP" "없음" "kolla-host-net.service 로그 확인(journalctl -u kolla-host-net)"; fi
if ip -4 addr show dev "$EXT_HOST_IF" 2>/dev/null | grep -q "inet ${EXT_GW_CIDR}"; then check_ok "$EXT_HOST_IF 에 게이트웨이" "$EXT_GW_CIDR"
else check_ng "$EXT_HOST_IF 에 게이트웨이" "$EXT_GW_CIDR" "없음" "veth 쌍 생성 실패"; fi
if ip link show "$EXT_IF" 2>/dev/null | grep -q 'UP'; then check_ok "$EXT_IF 상태 UP"
else check_ng "$EXT_IF 상태 UP" "UP" "아님" "veth 쌍 생성 실패"; fi
[[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)" == "1" ]] && check_ok "net.ipv4.ip_forward=1" \
  || check_ng "net.ipv4.ip_forward=1" "1" "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 확인불가)" "sysctl 파일 적용 실패"
if sudo -n iptables -t nat -S POSTROUTING 2>/dev/null | grep -q -- "-s ${EXT_NET_CIDR}.*MASQUERADE"; then check_ok "외부망 NAT(MASQUERADE) 규칙" "$EXT_NET_CIDR"
else check_ng "외부망 NAT(MASQUERADE) 규칙" "$EXT_NET_CIDR MASQUERADE" "없음" "VM 이 외부로 나가지 못한다. kolla-host-net.service 재시작"; fi

# ---------------------------------------------------------------- 호스트 이름과 globals.yml
[[ "$(hostname)" == "$KOLLA_HOSTNAME" ]] && check_ok "호스트 이름" "$KOLLA_HOSTNAME" || check_ng "호스트 이름" "$KOLLA_HOSTNAME" "$(hostname)" "localhost 이면 kolla-aio 점검이 실패한다"
for pair in "${KOLLA_GLOBALS[@]}"; do
  key="${pair%%|*}"; want="${pair#*|}"; cur="$(gv "$key")"
  [[ "$cur" == "$want" ]] && check_ok "globals.yml $key" "$cur" || check_ng "globals.yml $key" "$want" "${cur:-없음}" "apply.sh 의 globals 단계 재실행"
done

# ---------------------------------------------------------------- 호스트 libvirt 중지
bad=()
for u in "${KOLLA_HOST_LIBVIRT_UNITS[@]}"; do
  systemctl cat "$u" >/dev/null 2>&1 || continue
  if [[ "$u" == *.service ]] && systemctl is-active --quiet "$u" 2>/dev/null; then bad+=("$u"); fi
done
if [[ "${#bad[@]}" -eq 0 ]]; then check_ok "호스트 libvirt 서비스 유닛 비활성"
else check_ng "호스트 libvirt 서비스 유닛 비활성" "inactive" "active: ${bad[*]}" "nova_libvirt 와 소켓 충돌. systemctl disable --now 로 중지"; fi

# ---------------------------------------------------------------- Docker
if have_cmd docker; then check_ok "docker 설치" "$(docker --version 2>/dev/null | head -n1 || true)"
else check_ng "docker 설치" "docker 명령" "없음" "bootstrap 단계 미실행"; fi
systemctl is-active --quiet docker 2>/dev/null && check_ok "docker 서비스 active" || check_ng "docker 서비스 active" "active" "아님" "systemctl status docker"
if user_in_group_db docker; then check_ok "docker 그룹 구성원(DB)"
else check_ng "docker 그룹 구성원(DB)" "$(id -un) 포함" "없음" "sudo usermod -aG docker $(id -un)"; fi
if user_in_group_session docker; then check_ok "docker 그룹 세션 반영"
else check_warn "docker 그룹이 현재 세션에 없음" "재로그인(tmux 서버 재시작 포함) 필요. 3단계 kind 가 sudo 없이 docker 를 쓴다"; fi

# ---------------------------------------------------------------- Kolla 이미지와 컨테이너
nimg="$(sd images --format '{{.Repository}}' | grep -c '^quay.io/openstack.kolla/' || true)"
[[ "${nimg:-0}" -ge "$KOLLA_MIN_IMAGES" ]] && check_ok "Kolla 이미지 수" "${nimg}종" || check_ng "Kolla 이미지 수" ">= $KOLLA_MIN_IMAGES" "${nimg:-0}" "pull 미완료"

names="$(sd ps --format '{{.Names}}')"
for c in mariadb rabbitmq keystone glance_api nova_api nova_compute nova_libvirt neutron_server openvswitch_vswitchd heat_api; do
  grep -qx "$c" <<<"$names" && check_ok "컨테이너 실행" "$c" || check_ng "컨테이너 실행: $c" "Up" "없음" "deploy 실패 또는 미실행. docker ps -a 확인"
done
badc="$(sd ps -a --filter status=exited --filter status=restarting --format '{{.Names}}' | tr '\n' ' ')"
if [[ -z "${badc// }" ]]; then check_ok "비정상(exited/restarting) 컨테이너 없음"
else check_ng "비정상 컨테이너 없음" "없음" "$badc" "docker logs <이름> 확인"; fi
unh="$(sd ps --filter health=unhealthy --format '{{.Names}}' | tr '\n' ' ')"
if [[ -z "${unh// }" ]]; then check_ok "unhealthy 컨테이너 없음"
else check_ng "unhealthy 컨테이너 없음" "없음" "$unh" "docker logs <이름> 확인"; fi

# 외부 브리지: Neutron 이 br-ex 에 veth-ext 를 붙였는지
if sd exec openvswitch_vswitchd ovs-vsctl list-ports br-ex | grep -qx "$EXT_IF"; then check_ok "br-ex 에 $EXT_IF 연결"
else check_ng "br-ex 에 $EXT_IF 연결" "$EXT_IF 포트" "없음" "neutron_external_interface 설정 또는 openvswitch 컨테이너 확인"; fi

# ---------------------------------------------------------------- 자격 증명과 서비스
for f in "$KOLLA_CONFIG_DIR/admin-openrc.sh" "$KOLLA_CONFIG_DIR/clouds.yaml"; do
  if [[ -f "$f" ]]; then check_ok "파일 존재" "$f"; else check_ng "파일 존재: $f" "있음" "없음" "post-deploy 미실행"; fi
done
OSC="$KOLLA_VENV/bin/openstack"
if [[ -x "$OSC" && -f "$KOLLA_CONFIG_DIR/clouds.yaml" ]]; then
  export OS_CLIENT_CONFIG_FILE="$KOLLA_CONFIG_DIR/clouds.yaml"
  svc="$(timeout 60 "$OSC" --os-cloud "$KOLLA_CLOUD" catalog list -f value -c Name 2>/dev/null | sort -u | tr '\n' ' ' || true)"
  miss=()
  for s in $KOLLA_EXPECTED_SERVICES; do grep -qw "$s" <<<"$svc" || miss+=("$s"); done
  if [[ -n "${svc// }" && "${#miss[@]}" -eq 0 ]]; then check_ok "서비스 카탈로그" "$svc"
  else check_ng "서비스 카탈로그" "$KOLLA_EXPECTED_SERVICES" "${svc:-조회 실패}${miss[*]:+ (없음: ${miss[*]})}" "keystone 응답 확인. clouds.yaml 의 cloud 이름은 $KOLLA_CLOUD"; fi
  cs="$(timeout 60 "$OSC" --os-cloud "$KOLLA_CLOUD" compute service list -f value -c Binary -c State 2>/dev/null | grep -c ' up$' || true)"
  [[ "${cs:-0}" -ge 3 ]] && check_ok "nova 서비스 up" "${cs}개" || check_ng "nova 서비스 up" ">= 3" "${cs:-0}" "nova-compute 등 미기동"
else
  check_ng "OpenStack CLI 조회" "openstack, clouds.yaml 사용 가능" "불가" "0단계 venv, post-deploy 확인"
fi

report_summary || die "점검 실패. 위 [FAIL] 항목을 해결한 뒤 다시 실행하세요." "$EXIT_FAIL"
log_done "1단계 사후 점검 통과"
