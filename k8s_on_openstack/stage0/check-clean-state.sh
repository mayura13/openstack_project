#!/usr/bin/env bash
# stage0/check-clean-state.sh — 회차 시작 전 "깨끗한 상태" 확인.
# 평가 회차를 시작하기 전에, 이전 구축의 잔재가 없는지 O/X로 판정한다. 읽기 전용이며 아무것도 지우지 않는다.
# 이미 구축된 서버에서는 FAIL 이 나오는 것이 정상이다(잔재가 있다는 뜻). 정리는 사용자 승인 후 직접 한다.
#
# 확인 대상(브리프 6장): Kolla 컨테이너, kind 클러스터, Terraform 상태 파일, 호스트 libvirt 계열 유닛,
#                        이전 키트(OpenStack on Kubernetes)의 libvirt VM·네트워크·스토리지 풀
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage0 check-clean-state

log_info "초기 상태(깨끗한 서버) 확인을 시작합니다 (로그: $KIT_LOG_FILE)"

# ---------------------------------------------------------------- Docker 컨테이너 (Kolla 포함)
DOCKER_OK=0
if ! have_cmd docker; then
  check_ok "Docker 컨테이너 없음" "docker 미설치"
  check_ok "kind 클러스터 없음" "docker 미설치"
elif ! docker ps -a >/dev/null 2>&1; then
  # 접근할 수 없으면 "없음"으로 간주하지 않는다. 있는데 못 보는 것일 수 있다.
  check_ng "Docker 컨테이너 없음" "docker ps -a 로 확인 가능" "확인 불가" \
    "docker 그룹이 현재 세션에 적용되지 않았거나 서비스가 꺼져 있다. 재로그인 후 다시 실행하거나 'sudo docker ps -a' 로 직접 확인"
  check_ng "kind 클러스터 없음" "docker 로 확인 가능" "확인 불가" "위 Docker 접근 문제와 같다"
else
  DOCKER_OK=1
  total="$(docker ps -a -q | wc -l | tr -d ' ')"
  if [[ "$total" -eq 0 ]]; then
    check_ok "Docker 컨테이너 없음"
  else
    names="$(docker ps -a --format '{{.Names}}' | head -n5 | tr '\n' ' ')"
    check_ng "Docker 컨테이너 없음" "0개" "${total}개 (예: ${names}...)" \
      "이전 Kolla-Ansible 배포 또는 kind 클러스터가 남아 있다. 'docker ps -a' 로 확인하고 사용자 승인 후 정리"
  fi
fi

# ---------------------------------------------------------------- kind 클러스터
if [[ "$DOCKER_OK" -eq 1 ]]; then
  if have_cmd kind; then
    clusters="$(kind get clusters 2>/dev/null | tr '\n' ' ' || true)"
    if [[ -z "${clusters// /}" ]]; then
      check_ok "kind 클러스터 없음"
    else
      check_ng "kind 클러스터 없음" "없음" "$clusters" "'kind delete cluster --name <이름>' (사용자 승인 후)"
    fi
  else
    check_ok "kind 클러스터 없음" "kind 미설치"
  fi
fi

# ---------------------------------------------------------------- Terraform 상태
tfstates="$(compgen -G "$TF_COMMON_DIR/terraform.tfstate*" 2>/dev/null | head -n3 | tr '\n' ' ' || true)"
if [[ -z "$tfstates" ]]; then
  check_ok "Terraform 상태 파일 없음" "$TF_COMMON_DIR"
else
  check_ng "Terraform 상태 파일 없음" "없음" "$tfstates" \
    "공용 자원이 남아 있다. 상태 파일을 지우면 'terraform destroy' 로 지울 수 없게 되므로 destroy 를 먼저 실행"
fi

# ---------------------------------------------------------------- 호스트 libvirt 계열
active_units=()
for u in libvirtd.service libvirtd.socket virtlogd.service virtlogd.socket virtlockd.service virtlockd.socket; do
  systemctl is-active --quiet "$u" 2>/dev/null && active_units+=("$u")
done
if [[ "${#active_units[@]}" -eq 0 ]]; then
  check_ok "호스트 libvirt 계열 유닛 비활성"
else
  check_ng "호스트 libvirt 계열 유닛 비활성" "모두 비활성" "${active_units[*]}" \
    "Kolla 의 nova_libvirt 와 충돌한다. libvirtd 뿐 아니라 virtlogd/virtlockd 도 함께 중지 (1단계, 사용자 확인 후)"
fi

# ---------------------------------------------------------------- 이전 키트의 libvirt 자원
if have_cmd virsh; then
  vms="$(timeout 10 virsh -c qemu:///system list --all --name 2>/dev/null | sed '/^$/d' | tr '\n' ' ' || true)"
  nets="$(timeout 10 virsh -c qemu:///system net-list --all --name 2>/dev/null | sed '/^$/d' | tr '\n' ' ' || true)"
  pools="$(timeout 10 virsh -c qemu:///system pool-list --all --name 2>/dev/null | sed '/^$/d' | tr '\n' ' ' || true)"
  [[ -z "$vms" ]]   && check_ok "libvirt VM 없음"       || check_ng "libvirt VM 없음" "없음" "$vms" "이전 키트의 VM 이거나 Kolla nova_libvirt 안의 VM 이다(같은 소켓을 쓴다). 정체 확인 후 정리(사용자 승인 후)"
  [[ -z "$nets" ]]  && check_ok "libvirt 네트워크 없음" || check_ng "libvirt 네트워크 없음" "없음" "$nets" "이전 키트는 ${PREV_KIT_NET_CIDR} 를 썼다. Kolla 가 떠 있으면 nova_libvirt 의 네트워크일 수 있다. 정체 확인 후 정리(사용자 승인 후)"
  [[ -z "$pools" ]] && check_ok "libvirt 스토리지 풀 없음" || check_ng "libvirt 스토리지 풀 없음" "없음" "$pools" "이전 키트의 풀. 정리(사용자 승인 후)"
else
  check_ok "libvirt 자원 없음" "virsh 미설치 -> 없음으로 간주"
fi

# ---------------------------------------------------------------- Kolla 호스트 네트워크 흔적 (정보)
if ip link show kolla0 >/dev/null 2>&1; then
  check_warn "kolla0 인터페이스 존재" "1단계에서 만드는 호스트 네트워크가 이미 있다(멱등 스크립트라 재실행은 안전)"
fi

report_summary || die "깨끗한 상태가 아닙니다. 위 [FAIL] 항목을 사용자 승인 후 정리하고 다시 확인하세요. (이 스크립트는 아무것도 지우지 않습니다)" "$EXIT_FAIL"
log_done "깨끗한 상태 확인 통과"
