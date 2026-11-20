#!/usr/bin/env bash
# stage2/preflight.sh — 2단계 실행 전 점검. 읽기 전용.
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage2 preflight

log_info "2단계 사전 점검을 시작합니다 (로그: $KIT_LOG_FILE)"

[[ "$(id -u)" -ne 0 ]] && check_ok "root 가 아닌 일반 계정" || check_ng "root 가 아닌 일반 계정" "일반 계정" "root" "일반 계정으로 실행"
sudo_nopass && check_ok "sudo 비밀번호 없이 사용" || check_ng "sudo 비밀번호 없이 사용" "sudo -n true 성공" "실패" "sudoers NOPASSWD 필요"

# ---------------------------------------------------------------- 1단계 산출물
CFG="$KOLLA_CONFIG_DIR/clouds.yaml"
for f in "$KOLLA_CONFIG_DIR/admin-openrc.sh" "$CFG"; do
  [[ -r "$f" ]] && check_ok "파일 읽기 가능" "$f" || check_ng "파일 읽기 가능: $f" "읽기 가능" "불가" "1단계 post-deploy 가 끝나지 않았거나 권한 문제"
done
OSC="$KOLLA_VENV/bin/openstack"
if [[ -x "$OSC" && -r "$CFG" ]]; then
  nsvc="$(OS_CLIENT_CONFIG_FILE="$CFG" timeout 60 "$OSC" --os-cloud "$KOLLA_CLOUD" catalog list -f value -c Name 2>/dev/null | sort -u | wc -l || true)"
  [[ "${nsvc:-0}" -ge 7 ]] && check_ok "OpenStack 인증과 서비스 카탈로그" "${nsvc}개" \
    || check_ng "OpenStack 인증과 서비스 카탈로그" ">= 7개" "${nsvc:-0}" "1단계 postcheck 를 먼저 통과시킨다"
  nup="$(OS_CLIENT_CONFIG_FILE="$CFG" timeout 60 "$OSC" --os-cloud "$KOLLA_CLOUD" compute service list -f value -c Binary -c State 2>/dev/null | grep -c ' up$' || true)"
  [[ "${nup:-0}" -ge 3 ]] && check_ok "nova 서비스 up" "${nup}개" || check_ng "nova 서비스 up" ">= 3" "${nup:-0}" "nova-compute 확인"
else
  check_ng "OpenStack CLI 사용 가능" "$OSC, $CFG" "불가" "0, 1단계 산출물 확인"
fi

# ---------------------------------------------------------------- 외부 네트워크 경로
if sudo -n docker exec openvswitch_vswitchd ovs-vsctl list-ports br-ex 2>/dev/null | grep -qx "$EXT_IF"; then check_ok "br-ex 에 $EXT_IF 연결"
else check_ng "br-ex 에 $EXT_IF 연결" "$EXT_IF 포트" "없음" "1단계 호스트 네트워크와 neutron_external_interface 확인"; fi

# ---------------------------------------------------------------- 호스트 libvirt(virtlogd 포함) 중지
bad=()
for u in "${KOLLA_HOST_LIBVIRT_UNITS[@]}"; do
  systemctl cat "$u" >/dev/null 2>&1 || continue
  if systemctl is-active --quiet "$u" 2>/dev/null; then bad+=("$u"); fi
done
if [[ "${#bad[@]}" -eq 0 ]]; then check_ok "호스트 libvirt/virtlogd/virtlockd 유닛 비활성"
else check_ng "호스트 libvirt/virtlogd/virtlockd 유닛 비활성" "inactive" "active: ${bad[*]}" "VM 생성이 console.log 오류로 ERROR 가 된다(수동 구축 2단계). 1단계 apply 로 중지"; fi

# ---------------------------------------------------------------- KVM, 자원
if [[ -e /dev/kvm ]]; then
  if [[ -r /dev/kvm && -w /dev/kvm ]]; then check_ok "/dev/kvm 읽기·쓰기 가능"
  else check_warn "/dev/kvm 접근 불가($(stat -c '%A %U:%G' /dev/kvm))" "이미지 빌드할 때만 필요하다. 빌드가 계획에 있으면 apply.sh 가 ACL 로 허용한다(VM 삭제 등으로 사라질 수 있음)"; fi
else
  check_ng "/dev/kvm 존재" "있음" "없음" "BIOS 가상화 설정 확인. 이미지 빌드와 노드 VM 모두 KVM 이 필요하다"
fi
avail="$(disk_avail_gib "$HOME")"
[[ "${avail:-0}" -ge 20 ]] && check_ok "홈 디렉터리 여유 공간" "${avail}GiB" || check_ng "홈 디렉터리 여유 공간" ">= 20GiB" "${avail:-0}GiB" "ISO 3.2GiB + 결과 4.3GB + 빌드 임시 공간"
mem="$(mem_total_gib)"
[[ "${mem:-0}" -ge 16 ]] && check_ok "메모리(빌드 VM 4GiB 포함 여유)" "${mem}GiB" || check_ng "메모리" ">= 16GiB" "${mem:-0}GiB" "빌드 VM 과 OpenStack 이 함께 돈다"

# ---------------------------------------------------------------- 0단계 도구와 인터넷
tv="$(tool_version terraform)"
[[ "$tv" == "$TERRAFORM_VERSION" ]] && check_ok "terraform 버전" "$tv" || check_ng "terraform 버전" "$TERRAFORM_VERSION" "${tv:-없음}" "0단계 install 실행"
for t in "pkgs.k8s.io|https://pkgs.k8s.io/core:/stable:/${K8S_SERIES}/deb/Packages" "github.com|https://github.com/kubernetes-sigs/image-builder" \
         "releases.ubuntu.com|https://releases.ubuntu.com/" "registry.terraform.io|https://registry.terraform.io/.well-known/terraform.json"; do
  name="${t%%|*}"; code="$(http_code "${t#*|}")"
  [[ "$code" =~ ^(200|301|302)$ ]] && check_ok "접속: $name" "HTTP $code" || check_ng "접속: $name" "응답 있음" "HTTP ${code:-없음}" "방화벽, DNS, 프록시 확인"
done

# ---------------------------------------------------------------- 알림
if [[ -z "${TMUX:-}" && -z "${STY:-}" ]]; then check_warn "tmux/screen 밖에서 실행 중" "이미지 빌드(약 31분)가 필요하면 apply.sh 가 tmux 안에서만 실행하도록 막는다"; fi
if have_cmd docker && OS_CLIENT_CONFIG_FILE="$CFG" timeout 60 "$OSC" --os-cloud "$KOLLA_CLOUD" image show "$NODE_IMAGE_NAME" -f value -c status 2>/dev/null | grep -qx active; then
  check_warn "노드 이미지가 이미 있음" "apply.sh 는 빌드를 건너뛴다"
fi

report_summary || die "점검 실패. 위 [FAIL] 항목을 해결한 뒤 다시 실행하세요." "$EXIT_FAIL"
log_done "2단계 사전 점검 통과"
