#!/usr/bin/env bash
# stage1/apply.sh — 1단계: 호스트 네트워크를 만들고 Kolla-Ansible 로 OpenStack 을 배포한다.
#
# 모든 단계는 멱등이다. 이미 충족된 단계는 건너뛰고, 필요한 단계만 계획으로 출력한 뒤 실행한다.
#   --dry-run  변경 없이 실행 계획만 출력 (이미 구축된 서버에서는 전부 SKIP 이어야 한다)
#   --yes      호스트 변경 확인 질문 없이 진행
#
# 순서 (수동 구축 history 의 # MANUAL 1 구간과 인계 메모를 따름)
#   host_net -> hostname -> globals -> libvirt -> bootstrap -> prechecks -> pull -> deploy -> postdeploy -> docker_group
#
# 수동 구축에서 얻은 규칙
#  - 단일 NIC: kolla0(dummy) + veth 쌍으로 Kolla 의 2-NIC 요구를 대체한다. 기존 방화벽 파일과 eth0 설정은 건드리지 않는다.
#  - 호스트 libvirtd 뿐 아니라 virtlogd/virtlockd 도 중지한다(2단계에서 발견한 누락). 호스트에 실행 중인 VM 이 있으면 중단한다.
#  - enable_haproxy=no 이고 VIP 가 호스트 IP 이면 enable_proxysql=no 도 필요하다(MariaDB 3306 충돌).
#  - --use-test-images 는 prechecks 만 받는다. pull, deploy 는 unrecognized arguments 로 실패한다.
#  - 이미 배포된 서버(keystone, nova_compute, mariadb 실행 중)에서는 prechecks/pull/deploy 를 다시 하지 않는다. FORCE_REDEPLOY=1 로만 재실행.
#  - 기존 파일은 덮어쓰지 않는다(호스트 네트워크 스크립트는 3~4단계가 규칙을 덧붙이므로 특히).
#  - docker 그룹 추가는 마지막 단계다. 새 로그인에서만 적용되므로 끝나면 종료 코드 2 로 재접속을 안내한다.
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage1 apply
use_kolla_venv

HERE="$KIT_ROOT/stage1"
GLOBALS="$KOLLA_CONFIG_DIR/globals.yml"
VIP_CIDR="${KOLLA_VIP}/${KOLLA_VIP_PREFIX}"
KOLLA_ANSIBLE="$KOLLA_VENV/bin/kolla-ansible"

KIT_TMP=""
trap '[[ -n "$KIT_TMP" ]] && rm -rf "$KIT_TMP"' EXIT
tmpdir() { [[ -n "$KIT_TMP" ]] || KIT_TMP="$(mktemp -d)"; echo "$KIT_TMP"; }

# ------------------------------------------------------------------ 진단 (실패 시 run_step 이 호출)
kit_diagnose() {
  local t; t="$(tail -n 400 "$1" 2>/dev/null || true)"
  grep -qE "No module named 'docker'|Failed to import the required Python library.*docker" <<<"$t" \
    && hint "docker 파이썬 모듈 없음" "venv 에 docker, dbus-python 설치(stage0/install.sh 가 설치한다)"
  grep -q "Check if using quay.io/openstack.kolla images" <<<"$t" \
    && hint "Quay 기본 이미지는 테스트용 표시" "prechecks 에만 --use-test-images 를 붙인다"
  grep -q "Hostname has to resolve uniquely" <<<"$t" \
    && hint "호스트 이름 해석 실패" "호스트 이름이 localhost 이거나 /etc/hosts 에서 여러 IP 로 해석된다. hostname 과 getent ahostsv4 확인"
  grep -q "libvirt-sock" <<<"$t" \
    && hint "호스트 libvirtd 와 nova_libvirt 충돌" "호스트 libvirt 계열 유닛(libvirtd, virtlogd, virtlockd)을 중지한다"
  grep -qE "Address already in use|Port liveness|port liveness" <<<"$t" \
    && hint "MariaDB 3306 충돌" "enable_proxysql 기본값이 true 라 proxysql 이 3306 을 차지했을 수 있다. enable_proxysql: \"no\" 후 'docker rm -f proxysql', deploy 재실행"
  grep -q "unrecognized arguments" <<<"$t" \
    && hint "옵션 오류" "--use-test-images 는 prechecks 만 받는다"
  return 0
}

# ------------------------------------------------------------------ 조회 함수
sudo_docker() { sudo -n docker "$@"; }

is_deployed() {   # Kolla 핵심 컨테이너가 실행 중이면 배포된 서버로 본다
  local names; names="$(sudo_docker ps --format '{{.Names}}' 2>/dev/null || true)"
  grep -qx keystone <<<"$names" && grep -qx nova_compute <<<"$names" && grep -qx mariadb <<<"$names"
}

global_value() {  # 활성 줄의 값만 큰따옴표 제거해 출력. 없으면 빈 문자열
  [[ -f "$GLOBALS" ]] || return 0
  { grep -E "^$1:" "$GLOBALS" | head -n1 | sed -E 's/^[^:]+:[[:space:]]*//; s/[[:space:]]+$//; s/^"//; s/"$//'; } || true
}

# set_global <키> <값>  : 활성 줄이 있으면 그 줄, 없으면 첫 주석 줄을 교체, 그것도 없으면 끝에 추가
set_global() {
  local key="$1" val="$2" line
  line="${key}: \"${val}\""
  if grep -qE "^${key}:" "$GLOBALS"; then
    sed -i "0,/^${key}:.*/s|^${key}:.*|${line}|" "$GLOBALS"
  elif grep -qE "^#${key}:" "$GLOBALS"; then
    sed -i "0,/^#${key}:.*/s|^#${key}:.*|${line}|" "$GLOBALS"
  else
    printf '%s\n' "$line" >>"$GLOBALS"
  fi
}

# /etc/hosts 에서 VIP 가 localhost 로 묶인 줄을 호스트 이름으로 바꾸고, VIP 줄이 없으면 추가한다. (멱등)
fix_hosts_entry() {
  if grep -qE "^${KOLLA_VIP//./\\.}[[:space:]]+localhost[[:space:]]*$" /etc/hosts; then
    sudo cp -n /etc/hosts /etc/hosts.bak-kolla
    sudo sed -i "s/^${KOLLA_VIP//./\\.}[[:space:]]\+localhost[[:space:]]*$/${KOLLA_VIP} ${KOLLA_HOSTNAME}/" /etc/hosts
  elif ! grep -qE "^${KOLLA_VIP//./\\.}[[:space:]].*\b${KOLLA_HOSTNAME}\b" /etc/hosts; then
    sudo cp -n /etc/hosts /etc/hosts.bak-kolla
    echo "${KOLLA_VIP} ${KOLLA_HOSTNAME}" | sudo tee -a /etc/hosts >/dev/null
  fi
}

host_resolves_to_vip() {
  local addrs; addrs="$(getent ahostsv4 "$KOLLA_HOSTNAME" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
  [[ "${addrs% }" == "$KOLLA_VIP" ]]
}

kolla_images_count() { sudo_docker images --format '{{.Repository}}' 2>/dev/null | grep -c '^quay.io/openstack.kolla/' || true; }

# ------------------------------------------------------------------ 단계 정의
# need_<id> : 실행이 필요하면 0, 이미 충족이면 1. REASON 에 이유를 남긴다.  do_<id> : 실제 실행.
STEPS=(host_net hostname globals libvirt bootstrap prechecks pull deploy postdeploy docker_group)
declare -A TITLE=(
  [host_net]="호스트 네트워크(${KOLLA_NET_IF}, ${EXT_IF}/${EXT_HOST_IF}, 방화벽·NAT, ip_forward) 영속화"
  [hostname]="호스트 이름 ${KOLLA_HOSTNAME}, /etc/hosts, 인벤토리"
  [globals]="globals.yml 설정(${#KOLLA_GLOBALS[@]}개 키)"
  [libvirt]="호스트 libvirt 계열 유닛 중지"
  [bootstrap]="Docker 설치(kolla-ansible bootstrap-servers)"
  [prechecks]="kolla-ansible prechecks"
  [pull]="kolla-ansible pull (이미지)"
  [deploy]="kolla-ansible deploy"
  [postdeploy]="kolla-ansible post-deploy (admin-openrc.sh, clouds.yaml)"
  [docker_group]="docker 그룹에 $(id -un) 추가"
)
REASON=""
LIBVIRT_TODO=()
GLOBALS_TODO=()

need_host_net() {
  local miss=()
  [[ -f "$HOST_NET_SCRIPT" ]] || miss+=("$HOST_NET_SCRIPT 없음")
  [[ -f "$HOST_NET_UNIT" ]]   || miss+=("systemd 유닛 없음")
  [[ -f "$HOST_NET_SYSCTL" ]] || miss+=("sysctl 파일 없음")
  systemctl is-enabled --quiet kolla-host-net.service 2>/dev/null || miss+=("서비스 enable 안 됨")
  ip link show "$KOLLA_NET_IF" >/dev/null 2>&1 || miss+=("$KOLLA_NET_IF 없음")
  ip link show "$EXT_IF" >/dev/null 2>&1       || miss+=("$EXT_IF 없음")
  if [[ "${#miss[@]}" -gt 0 ]]; then REASON="${miss[*]}"; return 0; fi
  REASON="파일 3개, 서비스 enabled, 인터페이스 있음 (기존 파일은 덮어쓰지 않음)"; return 1
}
do_host_net() {
  local d; d="$(tmpdir)"
  if [[ ! -f "$HOST_NET_SCRIPT" ]]; then
    sed -e "s|@KOLLA_IF@|${KOLLA_NET_IF}|g" -e "s|@VIP_CIDR@|${VIP_CIDR}|g" -e "s|@VIP@|${KOLLA_VIP}|g" \
        -e "s|@EXT_IF@|${EXT_IF}|g" -e "s|@EXT_HOST_IF@|${EXT_HOST_IF}|g" -e "s|@EXT_GW_CIDR@|${EXT_GW_CIDR}|g" \
        -e "s|@EXT_NET_CIDR@|${EXT_NET_CIDR}|g" -e "s|@HOST_NIC@|${HOST_NIC}|g" \
        "$HERE/host-net/kolla-host-net.sh.tpl" >"$d/kolla-host-net.sh"
    bash -n "$d/kolla-host-net.sh" || die "생성한 호스트 네트워크 스크립트에 문법 오류가 있습니다."
    run_step "호스트 네트워크 스크립트 설치" sudo install -m 0755 "$d/kolla-host-net.sh" "$HOST_NET_SCRIPT"
  fi
  [[ -f "$HOST_NET_UNIT" ]]   || run_step "systemd 유닛 설치" sudo install -m 0644 "$HERE/host-net/kolla-host-net.service" "$HOST_NET_UNIT"
  [[ -f "$HOST_NET_SYSCTL" ]] || run_step "sysctl 파일 설치" sudo install -m 0644 "$HERE/host-net/99-kolla-host.conf" "$HOST_NET_SYSCTL"
  run_step "ip_forward 적용" sudo sysctl -w net.ipv4.ip_forward=1
  run_step "systemd 재적재" sudo systemctl daemon-reload
  run_step "서비스 enable 과 실행" sudo systemctl enable kolla-host-net.service
  run_step "호스트 네트워크 적용(멱등 스크립트 재실행)" sudo systemctl restart kolla-host-net.service
}

need_hostname() {
  local miss=()
  [[ "$(hostname)" == "$KOLLA_HOSTNAME" ]] || miss+=("호스트 이름 $(hostname)")
  grep -qE '^localhost[[:space:]]' "$KOLLA_INVENTORY" 2>/dev/null && miss+=("인벤토리에 localhost 줄")
  grep -qE "^${KOLLA_VIP//./\\.}[[:space:]]+localhost[[:space:]]*$" /etc/hosts && miss+=("/etc/hosts 의 VIP 줄이 localhost")
  host_resolves_to_vip || miss+=("$KOLLA_HOSTNAME 이 $KOLLA_VIP 하나로 해석되지 않음")
  if [[ "${#miss[@]}" -gt 0 ]]; then REASON="${miss[*]}"; return 0; fi
  REASON="호스트 이름, 인벤토리, 해석 모두 일치"; return 1
}
do_hostname() {
  [[ "$(hostname)" == "$KOLLA_HOSTNAME" ]] || run_step "호스트 이름 변경" sudo hostnamectl set-hostname "$KOLLA_HOSTNAME"
  if grep -qE '^localhost[[:space:]]' "$KOLLA_INVENTORY"; then
    run_step "인벤토리 백업" cp -n "$KOLLA_INVENTORY" "${KOLLA_INVENTORY}.bak-kolla"
    run_step "인벤토리 호스트 이름 교체" sed -i "s/^localhost\\b/${KOLLA_HOSTNAME}/" "$KOLLA_INVENTORY"
  fi
  run_step "/etc/hosts 정리" fix_hosts_entry
}

need_globals() {
  GLOBALS_TODO=()
  local pair key want cur
  if [[ ! -f "$GLOBALS" ]]; then REASON="$GLOBALS 없음(0단계 필요)"; return 0; fi
  for pair in "${KOLLA_GLOBALS[@]}"; do
    key="${pair%%|*}"; want="${pair#*|}"; cur="$(global_value "$key")"
    [[ "$cur" == "$want" ]] || GLOBALS_TODO+=("${key}(현재 '${cur:-없음}' -> '${want}')")
  done
  if [[ "${#GLOBALS_TODO[@]}" -gt 0 ]]; then REASON="${GLOBALS_TODO[*]}"; return 0; fi
  REASON="${#KOLLA_GLOBALS[@]}개 키 모두 일치"; return 1
}
do_globals() {
  [[ -f "$GLOBALS" ]] || die "$GLOBALS 가 없습니다. 0단계(make install)를 먼저 실행하세요."
  run_step "globals.yml 백업(덮어쓰지 않음)" cp -n "$GLOBALS" "${GLOBALS}.orig"
  local pair
  for pair in "${KOLLA_GLOBALS[@]}"; do
    run_step "globals.yml: ${pair%%|*}" set_global "${pair%%|*}" "${pair#*|}"
  done
}

need_libvirt() {
  LIBVIRT_TODO=()
  local u
  for u in "${KOLLA_HOST_LIBVIRT_UNITS[@]}"; do
    systemctl cat "$u" >/dev/null 2>&1 || continue          # 유닛이 없으면(libvirt 미설치) 건너뜀
    if systemctl is-active --quiet "$u" 2>/dev/null || [[ "$(systemctl is-enabled "$u" 2>/dev/null || true)" == "enabled" ]]; then
      LIBVIRT_TODO+=("$u")
    fi
  done
  if [[ "${#LIBVIRT_TODO[@]}" -gt 0 ]]; then REASON="실행 중이거나 enable 됨: ${LIBVIRT_TODO[*]}"; return 0; fi
  REASON="호스트 libvirt 계열 유닛 모두 비활성(없음 포함)"; return 1
}
do_libvirt() {
  # 호스트 libvirtd 가 돌고 있을 때 실행 중인 VM 이 있으면 자동으로 끄지 않는다.
  if have_cmd virsh && systemctl is-active --quiet libvirtd.service 2>/dev/null; then
    local running; running="$(timeout 10 virsh -c qemu:///system list --name 2>/dev/null | sed '/^$/d' | tr '\n' ' ' || true)"
    if [[ -n "$running" && "${KIT_FORCE_LIBVIRT_STOP:-0}" != "1" ]]; then
      die "호스트 libvirt 에 실행 중인 VM 이 있습니다: ${running}. 직접 정리한 뒤 다시 실행하거나, 감수하려면 KIT_FORCE_LIBVIRT_STOP=1" "$EXIT_FAIL"
    fi
  fi
  run_step "호스트 libvirt 계열 유닛 중지·비활성" sudo systemctl disable --now "${LIBVIRT_TODO[@]}"
}

# /etc/apparmor.d/disable 은 폴더여야 한다. Kolla 의 apparmor_libvirt 역할이 그 안에 usr.sbin.libvirtd 링크를 만든다.
# 이전 구축에서 폴더가 없을 때 'ln -s ... /etc/apparmor.d/disable' 이 실행되면 폴더 이름 자체가 링크가 되고,
# bootstrap-servers 가 "Not a directory: /etc/apparmor.d/disable/usr.sbin.libvirtd" 로 실패한다(2026-11-24 확인).
fix_apparmor_disable_dir() {
  local d=/etc/apparmor.d/disable
  if [[ -L "$d" || ( -e "$d" && ! -d "$d" ) ]]; then
    local bak; bak="/var/backups/apparmor-disable.$(date +%Y%m%d%H%M%S)"
    log_warn "$d 가 폴더가 아닙니다($(stat -c '%F' "$d")). $bak 로 옮기고 폴더를 만듭니다."
    sudo mv "$d" "$bak" || return 1
  fi
  [[ -d "$d" ]] || sudo mkdir -p "$d"
}

need_bootstrap() {
  if have_cmd docker && systemctl is-active --quiet docker 2>/dev/null; then REASON="docker 설치됨, 서비스 active"; return 1; fi
  REASON="docker 없음 또는 서비스 비활성"; return 0
}
do_bootstrap() {
  run_step "/etc/apparmor.d/disable 폴더 확인" fix_apparmor_disable_dir
  run_step "kolla-ansible bootstrap-servers" "$KOLLA_ANSIBLE" bootstrap-servers -i "$KOLLA_INVENTORY"
  # bootstrap 이 /etc/hosts 에 VIP 를 localhost 로 묶는 줄을 쓸 수 있다(수동 구축에서 prechecks 실패의 원인). 다시 정리한다.
  run_step "bootstrap 후 /etc/hosts 재확인" fix_hosts_entry
}

need_prechecks() {
  if is_deployed && [[ "$FORCE_REDEPLOY" != "1" ]]; then REASON="이미 배포됨(keystone, nova_compute, mariadb 실행 중). 다시 하지 않음"; return 1; fi
  REASON="배포 전 점검"; return 0
}
do_prechecks() {
  KIT_SCREEN_FILTER='^(TASK|PLAY RECAP|fatal|kolla-aio +:|ERROR|FAILED)' \
    run_step "kolla-ansible prechecks" "$KOLLA_ANSIBLE" prechecks -i "$KOLLA_INVENTORY" --use-test-images
}

need_pull() {
  if is_deployed && [[ "$FORCE_REDEPLOY" != "1" ]]; then REASON="이미 배포됨. 다시 하지 않음"; return 1; fi
  local n; n="$(kolla_images_count)"
  if [[ "$n" -ge "$KOLLA_MIN_IMAGES" ]]; then REASON="이미지 ${n}종 >= ${KOLLA_MIN_IMAGES}"; return 1; fi
  REASON="이미지 ${n}종 < ${KOLLA_MIN_IMAGES}"; return 0
}
do_pull() {
  KIT_SCREEN_FILTER='^(TASK|PLAY RECAP|fatal|kolla-aio +:|ERROR|FAILED)' \
    run_step "kolla-ansible pull" "$KOLLA_ANSIBLE" pull -i "$KOLLA_INVENTORY"
}

need_deploy() {
  if is_deployed && [[ "$FORCE_REDEPLOY" != "1" ]]; then REASON="이미 배포됨. 다시 하지 않음 (재배포는 FORCE_REDEPLOY=1)"; return 1; fi
  REASON="컨테이너 미배포"; return 0
}
do_deploy() {
  KIT_SCREEN_FILTER='^(TASK|PLAY RECAP|fatal|kolla-aio +:|ERROR|FAILED)' \
    run_step "kolla-ansible deploy" "$KOLLA_ANSIBLE" deploy -i "$KOLLA_INVENTORY"
}

need_postdeploy() {
  local miss=()
  [[ -f "$KOLLA_CONFIG_DIR/admin-openrc.sh" ]] || miss+=("admin-openrc.sh")
  [[ -f "$KOLLA_CONFIG_DIR/clouds.yaml" ]]     || miss+=("clouds.yaml")
  if [[ "${#miss[@]}" -gt 0 ]]; then REASON="없음: ${miss[*]}"; return 0; fi
  if [[ " ${PLAN[*]:-} " == *" deploy "* ]]; then REASON="deploy 를 새로 실행하므로 다시 생성"; return 0; fi
  REASON="admin-openrc.sh, clouds.yaml 있음"; return 1
}
do_postdeploy() {
  KIT_SCREEN_FILTER='^(TASK|PLAY RECAP|fatal|kolla-aio +:|ERROR|FAILED)' \
    run_step "kolla-ansible post-deploy" "$KOLLA_ANSIBLE" post-deploy -i "$KOLLA_INVENTORY"
}

need_docker_group() {
  if user_in_group_db docker; then REASON="이미 docker 그룹 구성원"; return 1; fi
  REASON="docker 그룹 구성원이 아님(kind 가 3단계에서 sudo 없이 docker 를 쓴다)"; return 0
}
do_docker_group() { run_step "docker 그룹 추가" sudo usermod -aG docker "$(id -un)"; }

# ------------------------------------------------------------------ 계획 수립
log_info "1단계 계획을 세웁니다 (로그: $KIT_LOG_FILE)"
PLAN=()
for id in "${STEPS[@]}"; do
  REASON=""
  if "need_$id"; then
    PLAN+=("$id")
    log_info "[실행 예정] ${TITLE[$id]} — $REASON"
  else
    log_skip "${TITLE[$id]} — $REASON"
  fi
done

if [[ "${#PLAN[@]}" -eq 0 ]]; then
  log_done "할 일이 없습니다. 모든 항목이 이미 충족되어 있습니다."
elif [[ "$KIT_DRY_RUN" == "1" ]]; then
  log_info "(dry-run) 위 [실행 예정] ${#PLAN[@]}개 단계만 실제 실행 시 변경됩니다. 아무것도 바꾸지 않고 종료합니다."
  report_summary || true
  exit "$EXIT_OK"
else
  sudo_nopass || die "sudo 를 비밀번호 없이 쓸 수 없습니다. 'sudo -n true' 가 성공해야 합니다." "$EXIT_FAIL"
  impact="${#PLAN[@]}개 단계 실행:"
  [[ " ${PLAN[*]} " == *" host_net "* ]]   && impact+=" 호스트 네트워크(인터페이스 ${KOLLA_NET_IF}/${EXT_IF}/${EXT_HOST_IF} 생성, iptables 규칙과 NAT 추가, ip_forward, systemd 서비스; ${HOST_NIC} 설정과 SSH 경로는 바꾸지 않음);"
  [[ " ${PLAN[*]} " == *" hostname "* ]]   && impact+=" 호스트 이름 변경과 /etc/hosts 수정;"
  [[ " ${PLAN[*]} " == *" libvirt "* ]]    && impact+=" 호스트 libvirt 유닛 중지;"
  [[ " ${PLAN[*]} " == *" bootstrap "* ]]  && impact+=" Docker 설치와 /etc/docker 설정;"
  [[ " ${PLAN[*]} " == *" deploy "* ]]     && impact+=" OpenStack 컨테이너 배포(약 25분);"
  [[ " ${PLAN[*]} " == *" docker_group "* ]] && impact+=" docker 그룹 추가;"
  confirm "$impact" "호스트 네트워크: 'sudo systemctl disable --now kolla-host-net.service' 후 'sudo ip link del ${KOLLA_NET_IF}; sudo ip link del ${EXT_IF}' 와 추가된 iptables 규칙 삭제. 그 외는 단계별 수동 복구(로그: $KIT_LOG_FILE)"
fi

# ------------------------------------------------------------------ 실행
for id in "${PLAN[@]}"; do
  log_step "== ${TITLE[$id]}"
  "do_$id"
done

# ------------------------------------------------------------------ 재접속 필요 여부
# 그룹은 로그인 시점에 고정된다. 이미 떠 있는 tmux 서버도 이전 그룹을 유지한다.
if user_in_group_db docker && ! user_in_group_session docker; then
  report_summary || true
  log_warn "docker 그룹이 현재 세션에 적용되지 않았습니다. 이것은 실패가 아니라 설계된 중단입니다."
  log_info "1) 로그아웃 후 다시 로그인(새 SSH 세션)  2) tmux 를 쓰고 있었다면 tmux 서버를 종료하고 새로 시작  3) 'make stage-1' 다시 실행(완료된 단계는 건너뜁니다)"
  exit "$EXIT_RELOGIN"
fi

report_summary || true
log_done "1단계 실행 완료"
