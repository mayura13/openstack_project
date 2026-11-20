#!/usr/bin/env bash
# verify/all.sh — 검증 a~f 를 한 번에 실행하고 표로 요약한다. 삭제는 하지 않는다.
#   a  stage2/verify-a.sh    테스트 VM 을 만들었다가 항상 지운다(OpenStack 이 살아 있으면 실행)
#   b~e stage5/verify-bcde.sh 워크로드 클러스터가 있으면 실행(시험 네임스페이스는 항상 지운다)
#   f  stage6/verify-f.sh    삭제 전후 기록(STAGE6_DIR)이 있으면 실행. 없으면 SKIP
# 클러스터가 삭제된 상태라면 b~e 는 SKIP, 삭제 직후라면 f 만 의미가 있다.
# 종료 코드: 0(실행한 검증이 모두 통과), 1(하나라도 실패)
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init verify all
source "$KIT_ROOT/stage6/lib6.sh"

declare -A RES=() WHY=()
run_one() {   # <키> <설명> <스크립트>
  local k="$1" title="$2" sc="$3" rc=0
  log_step "== 검증 ${title}"
  bash "$KIT_ROOT/$sc" || rc=$?
  if [[ "$rc" -eq 0 ]]; then RES[$k]="PASS"; else RES[$k]="FAIL"; WHY[$k]="$sc 종료 코드 $rc (자세한 내용은 위 출력과 logs/ 참고)"; fi
}
skip_one() { RES[$1]="SKIP"; WHY[$1]="$2"; log_skip "검증 $1: $2"; }

log_info "전체 검증을 시작합니다 (로그: $KIT_LOG_FILE)"
if os server list -f value -c ID >/dev/null 2>&1; then run_one a "a: OpenStack 기반(테스트 VM)" stage2/verify-a.sh
else skip_one a "OpenStack 에 접속할 수 없음"; fi

if [[ -s "$CLUSTER_KUBECONFIG" ]] && timeout 30 "$KUBECTL" --kubeconfig "$CLUSTER_KUBECONFIG" get nodes >/dev/null 2>&1; then
  run_one bcde "b~e: 클러스터, 배포 상태, 서비스, 클라우드 연동" stage5/verify-bcde.sh
else skip_one bcde "워크로드 클러스터가 없거나 접속할 수 없음(삭제했다면 정상)"; fi

if mkc -n default get cluster "$CLUSTER_NAME" >/dev/null 2>&1; then
  skip_one f "클러스터 ${CLUSTER_NAME} 가 다시 만들어져 있음(삭제 검증 기록이 오래된 것. 삭제 직후에만 의미가 있다)"
elif [[ -s "$STAGE6_DIR/before/taken-at.txt" && -s "$STAGE6_DIR/after/taken-at.txt" ]]; then run_one f "f: 삭제(CAPO 자원 정리, Terraform 자원 보존)" stage6/verify-f.sh
else skip_one f "삭제 전후 기록이 없음(6단계를 실행하지 않았다면 정상)"; fi

echo
echo "===== 검증 요약 ====="
fail=0; ran=0
for k in a bcde f; do
  printf '  %-5s %-5s %s\n' "$k" "${RES[$k]}" "${WHY[$k]:-}"
  [[ "${RES[$k]}" == "FAIL" ]] && fail=1
  [[ "${RES[$k]}" != "SKIP" ]] && ran=$((ran + 1))
done
if [[ "$ran" -eq 0 ]]; then log_warn "실행된 검증이 없습니다."; exit "$EXIT_FAIL"; fi
[[ "$fail" -eq 0 ]] && { log_done "실행한 검증이 모두 통과했습니다."; exit "$EXIT_OK"; }
die "실패한 검증이 있습니다." "$EXIT_FAIL"
