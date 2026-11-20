#!/usr/bin/env bash
# stage6/apply.sh — 6단계: 워크로드 클러스터 삭제와 검증 f. 되돌릴 수 없는 작업이다.
#
#   --dry-run  변경 없이 계획만 출력
#   --yes      다른 확인 질문(kubeconfig 삭제 등)만 건너뛴다. 클러스터 삭제 확인은 --yes 로 건너뛸 수 없다.
#              무인 실행이면 KIT_CONFIRM_DELETE=<클러스터 이름> 을 환경변수로 명시해야 한다.
#
# 순서: record_before -> delete -> wait_cleanup -> record_after -> compare -> leftovers
#
# 수동 구축에서 얻은 규칙
#  - 삭제는 관리 클러스터(kind-mgmt)가 처리한다. 검증이 끝날 때까지 관리 클러스터를 지우지 않는다.
#  - 삭제 전 OpenStack 상태를 기록해 두고 삭제 뒤와 이름·ID 로 비교한다(개수로 비교하면 틀린다. Floating IP 포트도 CAPO 자원이다).
#  - CAPO 자원(서버, 포트, Floating IP, 보안 그룹)은 사라지고, Terraform 자원(네트워크, 라우터, 키페어, flavor, 이미지)은 남아야 한다.
#  - 삭제 명령이 끝나도 OpenStack 정리가 끝났다는 보장은 없다(수동에서는 측정하지 않았다). 그래서 폴링으로 기다리고 시간을 기록한다.
#  - 클러스터 삭제로 지워지지 않는 것: 관리 클러스터의 Secret(admin 비밀번호 포함), 호스트의 워크로드 kubeconfig.
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage6 apply
source "$KIT_ROOT/stage6/lib6.sh"

BEFORE="$STAGE6_DIR/before"; AFTER="$STAGE6_DIR/after"; TIMING="$STAGE6_DIR/timing.txt"
cluster_exists() { mkc -n default get cluster "$CLUSTER_NAME" >/dev/null 2>&1; }
archive() { [[ -d "$1" ]] && mv "$1" "$1.$(date +%Y%m%d-%H%M%S)" || true; }

kit_diagnose() {
  local t; t="$(tail -n 300 "$1" 2>/dev/null || true)"
  grep -q "timed out waiting for the condition" <<<"$t" && hint "삭제가 ${DELETE_TIMEOUT} 안에 끝나지 않음" "kubectl --context $KUBE_CONTEXT get cluster,machine,openstackmachine -A 와 capo-controller-manager 로그 확인. 삭제는 계속 진행 중일 수 있으니 이 스크립트를 다시 실행하면 이어서 기다린다"
  return 0
}

STEPS=(record_before delete wait_cleanup record_after compare leftovers)
declare -A TITLE=(
  [record_before]="삭제 전 OpenStack 상태 기록 (${BEFORE})"
  [delete]="워크로드 클러스터 ${CLUSTER_NAME} 삭제 (관리 클러스터가 처리)"
  [wait_cleanup]="OpenStack 정리 완료 대기(서버, 클러스터 보안 그룹, API Floating IP)"
  [record_after]="삭제 후 OpenStack 상태 기록 (${AFTER})"
  [compare]="검증 f: CAPO 자원 정리, Terraform 자원 보존 (이름·ID 비교)"
  [leftovers]="남은 흔적 확인과 정리(워크로드 kubeconfig)"
)
REASON=""; PLAN=()

need_record_before() {
  mkc get nodes >/dev/null 2>&1 || die "관리 클러스터(${KUBE_CONTEXT})에 접속할 수 없습니다. 삭제는 관리 클러스터가 처리하므로 먼저 살아 있어야 합니다(3단계). 아무것도 변경하지 않았습니다." "$EXIT_FAIL"
  if cluster_exists; then REASON="클러스터가 있으므로 삭제 직전 상태를 기록"; return 0; fi
  REASON="클러스터 ${CLUSTER_NAME} 가 이미 없음(기록할 기준 상태 없음)"; return 1
}
do_record_before() {
  archive "$BEFORE"; archive "$AFTER"; mkdir -p "$STAGE6_DIR"
  run_step "삭제 전 상태 기록" snapshot "$BEFORE" capo
  [[ -s "$BEFORE/api_fip.txt" ]] || log_warn "API Floating IP 주소를 기록하지 못했습니다. Floating IP 정리는 확인하지 못합니다."
  local n; n="$(python3 -c 'import json,sys; print(sum(1 for r in json.load(open(sys.argv[1])) if r["Name"].startswith(sys.argv[2]+"-")))' "$BEFORE/server.json" "$CLUSTER_NAME")"
  [[ "$n" -ge 1 ]] || die "OpenStack 에 ${CLUSTER_NAME}-* 서버가 없습니다. 삭제할 클러스터가 아닌 것 같아 중단합니다." "$EXIT_FAIL"
  log_done "기록 완료: 서버 ${n}대, 포트 $(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$BEFORE/capo_ports.json")개(클러스터 소유), API Floating IP $(cat "$BEFORE/api_fip.txt")"
}

need_delete() { if cluster_exists; then REASON="Cluster ${CLUSTER_NAME} 있음"; return 0; fi; REASON="Cluster ${CLUSTER_NAME} 없음"; return 1; }
confirm_delete() {
  local vms fip
  vms="$(os server list -f value -c Name 2>/dev/null | { grep "^${CLUSTER_NAME}-" || true; } | tr '\n' ' ')"
  fip="$(mkc -n default get cluster "$CLUSTER_NAME" -o jsonpath='{.spec.controlPlaneEndpoint.host}' 2>/dev/null || true)"
  log_warn "삭제 대상: Cluster ${CLUSTER_NAME} 와 OpenStack 자원 — 서버 [${vms:-?}], API Floating IP ${fip:-?}, 포트, 보안 그룹 2개(5단계에서 추가한 Typha 규칙 포함)"
  log_warn "워크로드 클러스터 안의 모든 것(Calico, OCCM, 시험 배포)이 함께 사라지며 되돌릴 수 없습니다."
  log_info "남는 것: Terraform 공용 기반(네트워크, 라우터, 키페어, flavor, 이미지), 관리 클러스터, 인증 Secret, 주문서(${CLUSTER_MANIFEST})"
  log_info "복구 방법: 없음(삭제 자체는 되돌릴 수 없다). 같은 주문서로 4단계를 다시 실행하면 새 클러스터를 만들 수 있고, 5단계를 다시 해야 한다."
  if [[ "${KIT_CONFIRM_DELETE:-}" == "$CLUSTER_NAME" ]]; then log_info "KIT_CONFIRM_DELETE 가 클러스터 이름과 같으므로 진행합니다."; return 0; fi
  [[ -t 0 ]] || die "삭제 확인이 필요하지만 터미널이 아닙니다. 터미널에서 실행하거나 KIT_CONFIRM_DELETE=${CLUSTER_NAME} 로 명시하세요(--yes 로는 삭제 확인을 건너뛸 수 없습니다)." "$EXIT_USAGE"
  local ans; read -r -p "삭제하려면 클러스터 이름(${CLUSTER_NAME})을 그대로 입력하세요: " ans
  [[ "$ans" == "$CLUSTER_NAME" ]] || die "입력이 일치하지 않아 삭제하지 않았습니다." "$EXIT_FAIL"
}
do_delete() {
  confirm_delete
  local t0 t1; t0="$(date +%s)"; echo "delete_started=$(date -Is)" >>"$TIMING"
  run_step "kubectl delete cluster ${CLUSTER_NAME}" mkc -n default delete cluster "$CLUSTER_NAME" --timeout="$DELETE_TIMEOUT"
  t1="$(date +%s)"; echo "delete_command_secs=$((t1 - t0))" >>"$TIMING"; echo "delete_finished=$(date -Is)" >>"$TIMING"
  log_done "삭제 명령 종료 ($((t1 - t0))초)"
}

need_wait_cleanup() {
  local fip=""; [[ -s "$BEFORE/api_fip.txt" ]] && fip="$(cat "$BEFORE/api_fip.txt")"
  if cluster_exists; then REASON="삭제 후 확인이 필요"; return 0; fi
  local left; left="$(owned_left "$fip")"
  if [[ -n "$left" ]]; then REASON="OpenStack 에 아직 남음: ${left}"; return 0; fi
  REASON="OpenStack 에 클러스터 서버, 보안 그룹, Floating IP 없음"; return 1
}
do_wait_cleanup() {
  local fip="" waited=0 left=""; [[ -s "$BEFORE/api_fip.txt" ]] && fip="$(cat "$BEFORE/api_fip.txt")"
  local t0; t0="$(date +%s)"
  while :; do
    left="$(owned_left "$fip")"
    [[ -z "$left" ]] && break
    [[ "$waited" -lt "$CLEANUP_WAIT_SECS" ]] || { hint "${CLEANUP_WAIT_SECS}초 안에 정리되지 않음: ${left}" "CAPO 컨트롤러 로그와 남은 자원의 상태(예: 포트가 다른 자원에 물려 있는지)를 확인. 이 스크립트를 다시 실행하면 이어서 기다린다"; die "OpenStack 정리 시간 초과" "$EXIT_FAIL"; }
    (( waited % 30 == 0 )) && log_info "정리 대기 중 ${waited}초: ${left}"
    sleep 10; waited=$((waited + 10))
  done
  echo "cleanup_secs_after_delete_command=$(( $(date +%s) - t0 ))" >>"$TIMING"
  log_done "OpenStack 정리 확인 (삭제 명령 종료 후 확인까지 $(( $(date +%s) - t0 ))초)"
}

in_plan() { [[ " ${PLAN[*]:-} " == *" $1 "* ]]; }   # 앞 단계가 계획에 있으면 이 단계의 입력은 그 단계가 만든다
need_record_after() {
  if in_plan delete; then REASON="삭제 직후 상태를 기록"; return 0; fi
  if [[ ! -d "$BEFORE" ]]; then REASON="삭제 전 기록이 없어 비교할 수 없음"; return 1; fi
  if [[ ! -s "$AFTER/taken-at.txt" ]]; then REASON="삭제 후 기록 없음"; return 0; fi
  if [[ "$AFTER/taken-at.txt" -ot "$BEFORE/taken-at.txt" ]]; then REASON="삭제 후 기록이 삭제 전 기록보다 오래됨"; return 0; fi
  REASON="삭제 후 기록 있음"; return 1
}
do_record_after() { archive "$AFTER"; run_step "삭제 후 상태 기록" snapshot "$AFTER" nocapo; }

need_compare() {
  if in_plan record_after; then REASON="삭제 전후 기록으로 비교(읽기 전용)"; return 0; fi
  if [[ ! -s "$BEFORE/taken-at.txt" || ! -s "$AFTER/taken-at.txt" ]]; then REASON="삭제 전후 기록이 모두 필요"; return 1; fi
  REASON="전후 기록으로 비교(읽기 전용, 항상 실행)"; return 0
}
do_compare() {
  report_compare "$BEFORE" "$AFTER"
  report_summary || die "검증 f 실패. 위 [FAIL] 항목을 확인하세요(비교 기록: $STAGE6_DIR)." "$EXIT_FAIL"
}

need_leftovers() {
  local m=()
  [[ -e "$CLUSTER_KUBECONFIG" ]] && m+=("kubeconfig 파일")
  mkc -n default get secret "$CLOUD_SECRET_NAME" >/dev/null 2>&1 && m+=("인증 Secret")
  if [[ "${#m[@]}" -gt 0 ]]; then REASON="남아 있음: ${m[*]}"; return 0; fi
  REASON="정리할 흔적 없음"; return 1
}
do_leftovers() {
  if mkc -n default get secret "$CLOUD_SECRET_NAME" >/dev/null 2>&1; then
    check_warn "관리 클러스터의 Secret ${CLOUD_SECRET_NAME} 이 남아 있음(admin 비밀번호 포함)" "반복 구축에 쓰면 두고, 끝나면 kubectl --context ${KUBE_CONTEXT} -n default delete secret ${CLOUD_SECRET_NAME}. 키트는 자동으로 지우지 않는다"
  fi
  if [[ -e "$CLUSTER_KUBECONFIG" ]]; then
    confirm "워크로드 kubeconfig(${CLUSTER_KUBECONFIG}) 삭제 — 가리키던 클러스터가 없어 쓸 수 없고 관리자 인증 정보가 들어 있음" "4단계 apply 의 kubeconfig 단계에서 다시 만들 수 있다"
    rm -v -- "$CLUSTER_KUBECONFIG"
  fi
}

# ------------------------------------------------------------------ 계획 수립
log_info "6단계 계획을 세웁니다 (로그: $KIT_LOG_FILE)"
for id in "${STEPS[@]}"; do
  REASON=""
  if "need_$id"; then PLAN+=("$id"); log_info "[실행 예정] ${TITLE[$id]} — $REASON"
  else log_skip "${TITLE[$id]} — $REASON"; fi
done

if [[ "$KIT_DRY_RUN" == "1" ]]; then
  log_info "(dry-run) 아무것도 바꾸지 않고 종료합니다. 실제 실행 시 클러스터 삭제 전에 클러스터 이름을 직접 입력해야 합니다."
  report_summary || true
  exit "$EXIT_OK"
fi
if [[ "${#PLAN[@]}" -eq 0 ]]; then log_done "할 일이 없습니다."; exit "$EXIT_OK"; fi

for id in "${PLAN[@]}"; do
  log_step "== ${TITLE[$id]}"
  "do_$id"
done
log_done "6단계 완료. 시간 기록: $TIMING"
