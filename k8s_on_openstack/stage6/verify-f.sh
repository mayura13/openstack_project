#!/usr/bin/env bash
# stage6/verify-f.sh — 검증 f. 읽기 전용. apply.sh 가 남긴 삭제 전후 기록(STAGE6_DIR/before, after)을 이름·ID 로 비교한다.
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage6 verify-f
source "$KIT_ROOT/stage6/lib6.sh"
BEFORE="$STAGE6_DIR/before"; AFTER="$STAGE6_DIR/after"
log_info "검증 f 를 시작합니다 (기록: $STAGE6_DIR, 로그: $KIT_LOG_FILE)"
if [[ ! -s "$BEFORE/taken-at.txt" || ! -s "$AFTER/taken-at.txt" ]]; then
  check_ng "삭제 전후 기록" "$BEFORE 와 $AFTER" "없음" "make stage6-apply 로 삭제 전후 기록을 만든다"
  report_summary || die "기록이 없습니다." "$EXIT_FAIL"
fi
log_info "삭제 전 기록: $(cat "$BEFORE/taken-at.txt"), 삭제 후 기록: $(cat "$AFTER/taken-at.txt")"
report_compare "$BEFORE" "$AFTER"
if mkc get nodes >/dev/null 2>&1; then
  n="$(mkc get cluster,machine,openstackcluster,openstackmachine -A --no-headers 2>/dev/null | { grep -c "$CLUSTER_NAME" || true; })"
  [[ "$n" -eq 0 ]] && check_ok "관리 클러스터에 ${CLUSTER_NAME} 관련 객체 없음" || check_ng "관리 클러스터의 ${CLUSTER_NAME} 객체" "0개" "${n}개" "삭제가 진행 중이거나 막혀 있다"
  bad="$(mkc get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed"{print $1"/"$2}' | tr '\n' ' ')"
  [[ -z "${bad// }" ]] && check_ok "관리 클러스터 파드 정상" || check_ng "관리 클러스터 비정상 파드" "없음" "$bad" "kubectl --context $KUBE_CONTEXT get pods -A"
else check_warn "관리 클러스터에 접속할 수 없어 객체 확인을 건너뜀" "$KUBE_CONTEXT"; fi
[[ -e "$CLUSTER_KUBECONFIG" ]] && check_warn "워크로드 kubeconfig 가 남아 있음" "$CLUSTER_KUBECONFIG (쓸 수 없는 관리자 인증 정보. apply.sh 가 확인 후 삭제한다)"
report_summary || die "검증 f 실패." "$EXIT_FAIL"
log_done "검증 f 통과"
