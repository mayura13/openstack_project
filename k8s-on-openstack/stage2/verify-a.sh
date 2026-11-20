#!/usr/bin/env bash
# stage2/verify-a.sh — 검증 수준 a: 임시 VM 을 하나 만들어 KVM 으로 부팅되는지 확인하고 항상 지운다.
# 확인: VM ACTIVE, libvirt 도메인 type='kvm', 콘솔 로그에 로그인 프롬프트.
# 변경: 임시 VM 1개(이름 접두사 kit-test). 종료할 때 성공/실패와 무관하게 삭제한다. floating IP 는 만들지 않는다.
# 외부 통신(floating IP, 보안 그룹)과 호스트 밖 접근은 이 스크립트가 확인하지 않는다.
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage2 verify-a

CFG="$KOLLA_CONFIG_DIR/clouds.yaml"
OSC="$KOLLA_VENV/bin/openstack"
os() { OS_CLIENT_CONFIG_FILE="$CFG" timeout 120 "$OSC" --os-cloud "$KOLLA_CLOUD" "$@"; }
VM="${TEST_VM_PREFIX}-kvm-$(date +%s)"
CREATED=0

cleanup() {
  if [[ "$CREATED" == "1" ]]; then
    log_info "임시 VM $VM 삭제"
    os server delete --wait "$VM" >/dev/null 2>&1 || log_warn "임시 VM 삭제 실패. 직접 지우세요: openstack server delete $VM"
  fi
}
trap cleanup EXIT

log_info "검증 a 를 시작합니다 (로그: $KIT_LOG_FILE)"
if [[ "$KIT_DRY_RUN" == "1" ]]; then log_info "(dry-run) 임시 VM $VM 을 만들지 않고 종료합니다."; exit "$EXIT_OK"; fi

# 사전 자원
[[ "$(os image show "$NODE_IMAGE_NAME" -f value -c status 2>/dev/null || true)" == "active" ]] && check_ok "이미지 active" "$NODE_IMAGE_NAME" || check_ng "이미지 active" "active" "없음" "tf_apply 미실행"
os flavor show "$NODE_FLAVOR" >/dev/null 2>&1 && check_ok "flavor" "$NODE_FLAVOR" || check_ng "flavor" "$NODE_FLAVOR" "없음" "tf_apply 미실행"
os network show "$K8S_NET_NAME" >/dev/null 2>&1 && check_ok "네트워크" "$K8S_NET_NAME" || check_ng "네트워크" "$K8S_NET_NAME" "없음" "tf_apply 미실행"
os keypair show "$NODE_KEYPAIR" >/dev/null 2>&1 && check_ok "키페어" "$NODE_KEYPAIR" || check_ng "키페어" "$NODE_KEYPAIR" "없음" "tf_apply 미실행"
[[ "$KIT_FAIL" -eq 0 ]] || { report_summary || true; die "전제 자원이 없어 VM 을 만들지 않습니다." "$EXIT_FAIL"; }

start=$SECONDS
CREATED=1
if os server create --image "$NODE_IMAGE_NAME" --flavor "$NODE_FLAVOR" --network "$K8S_NET_NAME" --key-name "$NODE_KEYPAIR" --wait "$VM" >>"$KIT_LOG_FILE" 2>&1; then
  check_ok "VM 생성 ACTIVE" "$VM, $((SECONDS - start))초"
else
  fault="$(os server show "$VM" -f value -c fault 2>/dev/null | head -c 300 || true)"
  check_ng "VM 생성 ACTIVE" "ACTIVE" "생성 실패 ${fault:+($fault)}" "호스트 virtlogd/virtlockd 실행 중이면 console.log 오류로 ERROR 가 된다. nova-compute.log 에서 인스턴스 ID 로 확인"
  report_summary || true; die "검증 a 실패" "$EXIT_FAIL"
fi

inst="$(os server show "$VM" -f value -c OS-EXT-SRV-ATTR:instance_name 2>/dev/null || true)"
dom="$(sudo -n docker exec nova_libvirt virsh dumpxml "$inst" 2>/dev/null | grep -m1 '<domain type' || true)"
if grep -q "type='kvm'" <<<"$dom"; then check_ok "libvirt 도메인 type=kvm" "$inst"
else check_ng "libvirt 도메인 type=kvm" "type='kvm'" "${dom:-조회 실패}" "KVM 가속 없이 qemu 로 도는 중이면 느려진다. virt_type 과 /dev/kvm 확인"; fi

ok=0
for _ in $(seq 1 30); do
  if os console log show "$VM" 2>/dev/null | grep -qE 'login:|Cloud-init .* finished'; then ok=1; break; fi
  sleep 3
done
[[ "$ok" == "1" ]] && check_ok "콘솔 로그에 로그인 프롬프트" || check_ng "콘솔 로그에 로그인 프롬프트" "login: 또는 cloud-init finished" "90초 안에 없음" "부팅 실패. openstack console log show $VM"

report_summary || die "검증 a 실패" "$EXIT_FAIL"
log_done "검증 a 통과 (임시 VM 은 종료 시 삭제됩니다)"
