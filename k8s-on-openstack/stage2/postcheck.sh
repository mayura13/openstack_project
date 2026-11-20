#!/usr/bin/env bash
# stage2/postcheck.sh — 2단계 완료 후 점검. 읽기 전용. (테스트 VM 은 만들지 않는다. 그것은 stage2/verify-a.sh)
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage2 postcheck

CFG="$KOLLA_CONFIG_DIR/clouds.yaml"
OSC="$KOLLA_VENV/bin/openstack"
IB_CAPI="$IB_DIR/images/capi"
os() { OS_CLIENT_CONFIG_FILE="$CFG" timeout 60 "$OSC" --os-cloud "$KOLLA_CLOUD" "$@" 2>/dev/null || true; }
log_info "2단계 사후 점검을 시작합니다 (로그: $KIT_LOG_FILE)"

# ---------------------------------------------------------------- 이미지 빌드 환경
cur="$(git -C "$IB_DIR" rev-parse --short=12 HEAD 2>/dev/null || true)"
[[ "$cur" == "$IB_COMMIT" ]] && check_ok "image-builder 커밋" "$cur" || check_ng "image-builder 커밋" "$IB_COMMIT" "${cur:-없음}" "versions.env 의 IB_COMMIT 과 다르다"
a="$("$IB_VENV/bin/python" -m pip show ansible-core 2>/dev/null | awk '/^Version:/{print $2}' || true)"
[[ "$a" == "$IB_ANSIBLE_CORE" ]] && check_ok "ib-venv ansible-core" "$a" || check_warn "ib-venv ansible-core ${a:-없음}" "기대 $IB_ANSIBLE_CORE (빌드가 끝난 뒤에는 필수 아님)"
p="$("$IB_CAPI/.local/bin/packer" version 2>/dev/null | head -n1 | sed 's/^Packer v//' || true)"
[[ "$p" == "$IB_PACKER" ]] && check_ok "Packer" "$p" || check_warn "Packer ${p:-없음}" "기대 $IB_PACKER (빌드가 끝난 뒤에는 필수 아님)"
# Kolla 환경이 image-builder 때문에 바뀌지 않았는지
kc="$(venv_pkg_version ansible-core)"
[[ "$kc" == "$ANSIBLE_CORE_VERSION" ]] && check_ok "kolla-venv ansible-core 불변" "$kc" || check_ng "kolla-venv ansible-core 불변" "$ANSIBLE_CORE_VERSION" "${kc:-없음}" "image-builder 의존성이 kolla-venv 에 설치되었을 수 있다"

# ---------------------------------------------------------------- 이미지 파일과 Glance
if [[ -f "$NODE_IMAGE_FILE" ]]; then
  fmt="$(qemu-img info "$NODE_IMAGE_FILE" 2>/dev/null | awk -F': ' '/file format/{print $2}' || true)"
  [[ "$fmt" == "qcow2" ]] && check_ok "노드 이미지 파일(qcow2)" "$(du -h "$NODE_IMAGE_FILE" | cut -f1)" || check_ng "노드 이미지 파일(qcow2)" "qcow2" "${fmt:-확인 불가}" "빌드가 중간에 실패했다"
else
  check_warn "노드 이미지 파일 없음" "Glance 에 이미 등록되어 있으면 문제 없다"
fi
st="$(os image show "$NODE_IMAGE_NAME" -f value -c status)"
[[ "$st" == "active" ]] && check_ok "Glance 이미지 active" "$NODE_IMAGE_NAME" || check_ng "Glance 이미지 active" "active" "${st:-없음}" "tf_apply 단계 미실행 또는 업로드 실패"

# ---------------------------------------------------------------- Terraform 자원
nets="$(os network list -f value -c Name | tr '\n' ' ')"
for n in "$EXT_NET_NAME" "$K8S_NET_NAME"; do grep -qw -- "$n" <<<"$nets" && check_ok "네트워크" "$n" || check_ng "네트워크: $n" "있음" "없음" "tf_apply 미실행"; done
ext_ext="$(os network show "$EXT_NET_NAME" -f value -c router:external)"
[[ "$ext_ext" == "External" || "$ext_ext" == "True" ]] && check_ok "$EXT_NET_NAME 는 external" || check_ng "$EXT_NET_NAME 는 external" "External" "${ext_ext:-없음}" "Terraform external=true"
subs="$(os subnet list -f value -c Name -c Subnet | tr '\n' ' ')"
for s in "ext-subnet 10.20.20.0/24" "k8s-subnet 10.0.0.0/24"; do grep -qF -- "$s" <<<"$subs" && check_ok "서브넷" "$s" || check_ng "서브넷: $s" "있음" "${subs:-없음}" "main.tf 와 설계 값이 다르다"; done
rs="$(os router show k8s-router -f value -c status)"
[[ "$rs" == "ACTIVE" ]] && check_ok "라우터 k8s-router ACTIVE" || check_ng "라우터 k8s-router ACTIVE" "ACTIVE" "${rs:-없음}" "tf_apply 미실행"
fv="$(os flavor show "$NODE_FLAVOR" -f value -c vcpus)"; fr="$(os flavor show "$NODE_FLAVOR" -f value -c ram)"; fd="$(os flavor show "$NODE_FLAVOR" -f value -c disk)"
[[ "$fv $fr $fd" == "4 8192 60" ]] && check_ok "flavor $NODE_FLAVOR" "4 vCPU, 8192MB, 60GB" || check_ng "flavor $NODE_FLAVOR" "vcpus 4, ram 8192, disk 60" "vcpus ${fv:-없음}, ram ${fr:-없음}, disk ${fd:-없음}" "main.tf 와 다르다"
kp="$(os keypair list -f value -c Name | tr '\n' ' ')"
grep -qw -- "$NODE_KEYPAIR" <<<"$kp" && check_ok "키페어" "$NODE_KEYPAIR" || check_ng "키페어: $NODE_KEYPAIR" "있음" "${kp:-없음}" "tf_apply 미실행"

# ---------------------------------------------------------------- Terraform 상태
if [[ -d "$TF_COMMON_DIR/.terraform" ]]; then
  cnt="$( ( cd "$TF_COMMON_DIR" && terraform state list 2>/dev/null | wc -l ) || true)"
  [[ "${cnt:-0}" -eq "$TF_RESOURCE_COUNT" ]] && check_ok "Terraform 관리 자원 수" "$cnt" || check_ng "Terraform 관리 자원 수" "$TF_RESOURCE_COUNT" "${cnt:-0}" "상태 파일 위치 확인($TF_COMMON_DIR)"
  rc=0
  ( set +u; source "$KOLLA_CONFIG_DIR/admin-openrc.sh"; cd "$TF_COMMON_DIR" && terraform plan -input=false -lock=false -detailed-exitcode >/dev/null 2>&1 ) || rc=$?
  [[ "$rc" -eq 0 ]] && check_ok "terraform plan: 변경 없음" || check_ng "terraform plan: 변경 없음" "종료 코드 0" "종료 코드 $rc" "상태와 실제 자원이 다르다. 'terraform plan' 을 직접 확인"
else
  check_ng "Terraform 초기화" "$TF_COMMON_DIR/.terraform" "없음" "tf_apply 미실행"
fi
[[ -f "$TF_COMMON_DIR/.gitignore" ]] && grep -q 'tfstate' "$TF_COMMON_DIR/.gitignore" && check_ok "Terraform 상태 파일은 .gitignore 대상" || check_ng "Terraform 상태 파일은 .gitignore 대상" "*.tfstate* 포함" "없음" "상태 파일에 비밀이 섞일 수 있다"

# ---------------------------------------------------------------- SSH 키 권한
if [[ -f "$NODE_KEY" ]]; then
  perm="$(stat -c '%a' "$NODE_KEY")"
  [[ "$perm" == "600" ]] && check_ok "개인 키 권한" "$perm" || check_ng "개인 키 권한" "600" "$perm" "chmod 600 $NODE_KEY"
else
  check_ng "개인 키" "$NODE_KEY" "없음" "keypair 단계 미실행"
fi
[[ -f "$NODE_KEY.pub" ]] && check_ok "공개 키" || check_ng "공개 키" "$NODE_KEY.pub" "없음" "keypair 단계 미실행"

# ---------------------------------------------------------------- 임시 자원 잔재
left="$(os server list -f value -c Name | grep -c "^${TEST_VM_PREFIX}" || true)"
[[ "${left:-0}" -eq 0 ]] && check_ok "검증용 임시 VM 잔재 없음" || check_warn "검증용 임시 VM ${left}개 남음" "openstack server delete 로 지운다(stage2/verify-a.sh 는 항상 지운다)"

report_summary || die "점검 실패. 위 [FAIL] 항목을 해결한 뒤 다시 실행하세요." "$EXIT_FAIL"
log_done "2단계 사후 점검 통과"
