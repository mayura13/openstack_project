#!/usr/bin/env bash
# stage6/preflight.sh — 6단계 실행 전 점검. 읽기 전용.
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage6 preflight
source "$KIT_ROOT/stage6/lib6.sh"
log_info "6단계 사전 점검을 시작합니다 (로그: $KIT_LOG_FILE)"
[[ "$(id -u)" -ne 0 ]] && check_ok "root 가 아닌 일반 계정" || check_ng "root 가 아닌 일반 계정" "일반 계정" "root" ""
cur="$(tool_version kubectl)"; [[ "$cur" == "$KUBECTL_VERSION" ]] && check_ok "kubectl 버전" "$cur" || check_ng "kubectl 버전" "$KUBECTL_VERSION" "${cur:-없음}" "0단계 install"
command -v python3 >/dev/null 2>&1 && check_ok "python3" || check_ng "python3" "있음" "없음" "sudo apt install python3"
mkc get nodes >/dev/null 2>&1 && check_ok "관리 클러스터 접속(삭제를 처리하는 곳)" "$KUBE_CONTEXT" || check_ng "관리 클러스터 접속" "$KUBE_CONTEXT 응답" "접속 불가" "3단계. 삭제는 관리 클러스터가 처리하므로 먼저 살아 있어야 한다"
if mkc -n default get cluster "$CLUSTER_NAME" >/dev/null 2>&1; then
  check_ok "삭제 대상 Cluster" "$CLUSTER_NAME"
  ph="$(mkc -n default get cluster "$CLUSTER_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "$ph" == "Provisioned" ]] && check_ok "Cluster phase" "$ph" || check_warn "Cluster phase 가 Provisioned 가 아님" "${ph:-없음} (삭제는 가능하지만 기준 상태가 불완전할 수 있다)"
  [[ -n "$(mkc -n default get cluster "$CLUSTER_NAME" -o jsonpath='{.spec.controlPlaneEndpoint.host}' 2>/dev/null || true)" ]] && check_ok "API 서버 주소 기록 가능" || check_warn "API 서버 주소를 읽지 못함" "Floating IP 정리는 확인하지 못한다"
else check_warn "Cluster ${CLUSTER_NAME} 가 없음" "삭제할 것이 없다. 이미 삭제했다면 verify-f 로 기록을 비교한다"; fi
[[ -r "$CFG" ]] && check_ok "파일 읽기 가능" "$CFG" || check_ng "파일 읽기 가능: $CFG" "읽기 가능" "불가" "1단계 post-deploy"
n="$({ os server list -f value -c Name 2>/dev/null || true; } | { grep -c "^${CLUSTER_NAME}-" || true; })"
[[ "$n" -ge 1 ]] && check_ok "OpenStack 의 클러스터 서버" "${n}대" || check_warn "OpenStack 에 ${CLUSTER_NAME}-* 서버가 없음" "삭제 전 기준 상태를 기록할 수 없다"
for nm in "$EXT_NET_NAME" "$K8S_NET_NAME"; do [[ -n "$(os network show "$nm" -c id -f value 2>/dev/null || true)" ]] && check_ok "보존 대상 네트워크" "$nm" || check_ng "보존 대상 네트워크: $nm" "있음" "없음" "2단계"; done
[[ -n "$(os image show "$NODE_IMAGE_NAME" -c id -f value 2>/dev/null || true)" ]] && check_ok "보존 대상 이미지" "$NODE_IMAGE_NAME" || check_ng "보존 대상 이미지" "있음" "없음" "2단계"
tmpd="$(mktemp -d)"
if snapshot "$tmpd" nocapo >/dev/null 2>"$tmpd/err.txt"; then check_ok "삭제 전 기록(OpenStack 11종 조회)을 만들 수 있음"
else check_ng "삭제 전 기록(OpenStack 11종 조회)" "모두 조회 가능" "$(head -c 200 "$tmpd/err.txt")" "삭제 전에 기준 상태를 기록할 수 없으면 삭제를 시작하지 않는다"; fi
rm -rf "$tmpd"
dsk="$(disk_avail_gib "$HOME")"; [[ "${dsk:-0}" -ge 1 ]] && check_ok "기록 저장 공간" "${dsk}GiB" || check_ng "기록 저장 공간" ">= 1GiB" "${dsk:-0}GiB" ""
log_info "기록 위치: $STAGE6_DIR (리소스 ID, IP 가 들어 있으므로 공개 저장소에 올리지 않는다)"
report_summary || die "점검 실패. 위 [FAIL] 항목을 해결한 뒤 다시 실행하세요." "$EXIT_FAIL"
log_done "6단계 사전 점검 통과"
