#!/usr/bin/env bash
# shellcheck disable=SC2034  # EXIT_* 등은 이 파일을 source 하는 스크립트가 사용한다
# common/common.sh — 모든 단계 스크립트가 source 하는 공통 함수.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../common/common.sh"
#   kit_init stage0 preflight
#
# 이 파일은 셸 옵션(set -e 등)을 직접 바꾸지 않는다. 각 스크립트가 `set -Eeuo pipefail`을 선언한다.
# (run_step 만 종료 코드를 얻기 위해 pipefail 을 켠다.)
#
# 종료 코드 규칙 (모든 단계 공통)
#   0  성공
#   1  검사 실패 또는 단계 실행 실패 (어느 단계, 어느 항목인지 출력됨)
#   2  재접속 후 재실행 필요 (그룹 변경 등). 설계된 중단이며 실패가 아님
#   3  사용법 또는 설정 오류 (잘못된 옵션, versions.env 누락 등)
#
# 출력 규칙
#   [PASS] 항목
#   [FAIL] 항목  + 기준값 / 실제값 / 가능한 원인
#   [WARN] 항목  (중단하지 않는 경고)
#   [INFO] 안내
#   [STEP] 단계 실행 시작, [DONE]/[SKIP] 완료/건너뜀
#   `grep -c '^\[FAIL\]' 로그` 로 실패 건수를 센다.

[[ -n "${_KIT_COMMON_LOADED:-}" ]] && return 0
_KIT_COMMON_LOADED=1

EXIT_OK=0
EXIT_FAIL=1
EXIT_RELOGIN=2
EXIT_USAGE=3

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KIT_ROOT

if [[ ! -f "$KIT_ROOT/versions.env" ]]; then
  echo "[FAIL] versions.env 를 찾을 수 없습니다: $KIT_ROOT/versions.env" >&2
  exit "$EXIT_USAGE"
fi
# shellcheck source=../versions.env
source "$KIT_ROOT/versions.env"

# 로그 위치. run-deploy.sh 가 회차별 폴더를 KIT_LOG_DIR 로 넘긴다.
: "${KIT_LOG_DIR:=$KIT_ROOT/logs/adhoc}"
# 1이면 확인 질문 없이 진행한다(무인 실행용).
: "${KIT_ASSUME_YES:=0}"
# 1이면 변경 없이 계획만 출력한다.
: "${KIT_DRY_RUN:=0}"

# ------------------------------------------------------------------ 출력과 로그
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  _C_RED=$'\033[31m'; _C_GRN=$'\033[32m'; _C_YEL=$'\033[33m'; _C_BLU=$'\033[34m'; _C_OFF=$'\033[0m'
else
  _C_RED=""; _C_GRN=""; _C_YEL=""; _C_BLU=""; _C_OFF=""
fi

KIT_STAGE=""
KIT_SCRIPT=""
KIT_LOG_FILE=""
KIT_PASS=0
KIT_FAIL=0
KIT_WARN=0
KIT_STARTED_AT=0

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

# 화면에는 색을 넣고, 로그 파일에는 색 없이 시각과 함께 남긴다.
_emit() {
  local color="$1" tag="$2"; shift 2
  local line="$*"
  printf '%s[%s]%s %s\n' "$color" "$tag" "$_C_OFF" "$line"
  if [[ -n "$KIT_LOG_FILE" ]]; then
    printf '%s [%s] %s\n' "$(_ts)" "$tag" "$line" >>"$KIT_LOG_FILE"
  fi
}

log_info() { _emit "$_C_BLU" INFO "$*"; }
log_warn() { _emit "$_C_YEL" WARN "$*"; }
log_step() { _emit "$_C_BLU" STEP "$*"; }
log_done() { _emit "$_C_GRN" DONE "$*"; }
log_skip() { _emit "$_C_GRN" SKIP "$*"; }

# 비밀 보호: 이 함수들은 값을 가공하지 않는다. 비밀이 될 수 있는 값(비밀번호, 토큰)은 호출부에서 넘기지 않는다.

# kit_init <stage> <script>
#   로그 파일을 열고, 검사 카운터를 초기화하고, 예기치 못한 오류를 단계·줄 번호와 함께 출력하는 trap 을 건다.
kit_init() {
  KIT_STAGE="${1:?stage 이름 필요}"
  KIT_SCRIPT="${2:?script 이름 필요}"
  mkdir -p "$KIT_LOG_DIR"
  KIT_LOG_FILE="$KIT_LOG_DIR/${KIT_STAGE}-${KIT_SCRIPT}.log"
  KIT_PASS=0; KIT_FAIL=0; KIT_WARN=0
  KIT_STARTED_AT=$SECONDS
  : >>"$KIT_LOG_FILE"
  printf '%s ===== %s/%s 시작 (user=%s) =====\n' "$(_ts)" "$KIT_STAGE" "$KIT_SCRIPT" "$(id -un)" >>"$KIT_LOG_FILE"
  trap '_on_err "$LINENO" "$BASH_COMMAND"' ERR
}

_on_err() {
  local line="$1" cmd="$2" rc=$?
  trap - ERR
  _emit "$_C_RED" FAIL "${KIT_STAGE}/${KIT_SCRIPT}: 예기치 못한 오류 (줄 ${line}, 종료 코드 ${rc})"
  _emit "$_C_RED" FAIL "  명령: ${cmd}"
  _emit "$_C_RED" FAIL "  로그: ${KIT_LOG_FILE}"
  exit "$EXIT_FAIL"
}

# die <메시지> [종료코드]
die() {
  local msg="$1" code="${2:-$EXIT_FAIL}"
  trap - ERR
  _emit "$_C_RED" FAIL "${KIT_STAGE:-kit}/${KIT_SCRIPT:-}: ${msg}"
  [[ -n "$KIT_LOG_FILE" ]] && _emit "$_C_RED" FAIL "  로그: ${KIT_LOG_FILE}"
  exit "$code"
}

# ------------------------------------------------------------------ 검사 판정 (O/X)
check_ok() {
  local name="$1" detail="${2:-}"
  KIT_PASS=$((KIT_PASS + 1))
  if [[ -n "$detail" ]]; then _emit "$_C_GRN" PASS "$name ($detail)"; else _emit "$_C_GRN" PASS "$name"; fi
}

# check_ng <항목> <기준값> <실제값> <가능한 원인>
check_ng() {
  local name="$1" expected="$2" actual="$3" cause="$4"
  KIT_FAIL=$((KIT_FAIL + 1))
  _emit "$_C_RED" FAIL "$name"
  printf '       기준값: %s\n       실제값: %s\n       가능한 원인: %s\n' "$expected" "$actual" "$cause"
  if [[ -n "$KIT_LOG_FILE" ]]; then
    printf '       기준값: %s\n       실제값: %s\n       가능한 원인: %s\n' "$expected" "$actual" "$cause" >>"$KIT_LOG_FILE"
  fi
}

# check_warn <항목> <메시지>   중단하지 않는 경고
check_warn() {
  KIT_WARN=$((KIT_WARN + 1))
  _emit "$_C_YEL" WARN "$1${2:+ — $2}"
}

# report_summary  검사 요약을 출력하고 FAIL 이 있으면 1, 없으면 0 을 반환한다.
report_summary() {
  local secs=$((SECONDS - KIT_STARTED_AT))
  printf '\n== %s/%s: %d PASS / %d FAIL / %d WARN (%ds) ==\n' \
    "$KIT_STAGE" "$KIT_SCRIPT" "$KIT_PASS" "$KIT_FAIL" "$KIT_WARN" "$secs"
  if [[ -n "$KIT_LOG_FILE" ]]; then
    printf '%s == %s/%s: %d PASS / %d FAIL / %d WARN (%ds) ==\n' \
      "$(_ts)" "$KIT_STAGE" "$KIT_SCRIPT" "$KIT_PASS" "$KIT_FAIL" "$KIT_WARN" "$secs" >>"$KIT_LOG_FILE"
  fi
  [[ "$KIT_FAIL" -eq 0 ]]
}

# ------------------------------------------------------------------ 단계 실행 래퍼
# run_step <이름> <명령...>
#   명령 출력을 화면과 로그에 함께 남기고, 소요 시간을 steps.tsv 에 기록한다.
#   실패하면 단계, 이름, 종료 코드, 로그 위치를 출력하고 중단한다.
#   비대화형 명령 전용이다. 확인 질문이 나오는 명령에는 쓰지 않는다(출력 파이프가 질문을 가린다).
run_step() {
  local name="$1"; shift
  local start=$SECONDS rc=0
  log_step "$name"
  if [[ "$KIT_DRY_RUN" == "1" ]]; then
    log_info "(dry-run) 실행하지 않음: $*"
    return 0
  fi
  printf '%s $ %s\n' "$(_ts)" "$*" >>"$KIT_LOG_FILE"
  # if 조건 안에서 실행하면 ERR trap 과 errexit 이 개입하지 않는다. pipefail 로 명령의 종료 코드를 얻는다.
  # KIT_SCREEN_FILTER 가 있으면 화면에는 그 정규식에 맞는 줄만 보이고, 로그 파일에는 전부 남는다.
  set -o pipefail
  if [[ -n "${KIT_SCREEN_FILTER:-}" ]]; then
    if "$@" 2>&1 | tee -a "$KIT_LOG_FILE" | { grep --line-buffered -E "$KIT_SCREEN_FILTER" || true; }; then rc=0; else rc=$?; fi
  else
    if "$@" 2>&1 | tee -a "$KIT_LOG_FILE"; then rc=0; else rc=$?; fi
  fi
  local dur=$((SECONDS - start))
  printf '%s\t%s\t%s\t%d\t%d\n' "$KIT_STAGE" "$name" "$(_ts)" "$dur" "$rc" >>"$KIT_LOG_DIR/steps.tsv"
  if [[ "$rc" -ne 0 ]]; then
    trap - ERR
    _emit "$_C_RED" FAIL "${KIT_STAGE}/${KIT_SCRIPT}: 단계 '${name}' 실패 (종료 코드 ${rc}, ${dur}s)"
    _emit "$_C_RED" FAIL "  명령: $*"
    _emit "$_C_RED" FAIL "  로그: ${KIT_LOG_FILE}"
    # 단계 스크립트가 kit_diagnose <로그파일> 을 정의했으면 알려진 실패 원인을 안내한다.
    if declare -F kit_diagnose >/dev/null; then kit_diagnose "$KIT_LOG_FILE" || true; fi
    exit "$EXIT_FAIL"
  fi
  log_done "$name (${dur}s)"
}

# confirm <영향 설명> <복구 방법>
#   호스트를 바꾸는 작업 전에 확인을 받는다. KIT_ASSUME_YES=1 이면 묻지 않고 기록만 남긴다.
confirm() {
  local impact="$1" recovery="${2:-}"
  log_warn "호스트 변경: $impact"
  [[ -n "$recovery" ]] && log_info "복구 방법: $recovery"
  if [[ "$KIT_ASSUME_YES" == "1" ]]; then
    log_info "KIT_ASSUME_YES=1 이므로 확인 없이 진행합니다."
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "확인이 필요하지만 터미널이 아닙니다. 터미널에서 실행하거나 KIT_ASSUME_YES=1 로 명시하세요." "$EXIT_USAGE"
  fi
  local ans
  read -r -p "계속할까요? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || die "사용자가 취소했습니다." "$EXIT_FAIL"
}

# ------------------------------------------------------------------ 조회 함수
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# version_ge <현재> <최소>   현재 >= 최소 이면 0
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

# http_code <URL>   HTTP 응답 코드를 출력한다. 연결 실패는 000.
http_code() {
  curl -s -o /dev/null -m "${NET_TIMEOUT:-10}" -w '%{http_code}' "$1" 2>/dev/null || true
}

# sudo 를 비밀번호 없이 쓸 수 있는가 (무인 실행의 전제)
sudo_nopass() { sudo -n true 2>/dev/null; }

# 사용자가 그룹의 구성원으로 등록되어 있는가 (/etc/group 기준)
user_in_group_db() { getent group "$1" 2>/dev/null | awk -F: '{print $4}' | tr ',' '\n' | grep -qx "$(id -un)"; }

# 현재 셸 세션에서 그룹이 적용되어 있는가 (로그인 시점에 고정됨)
user_in_group_session() { id -nG 2>/dev/null | tr ' ' '\n' | grep -qx "$1"; }

# 사람이 읽기 쉬운 값으로 변환
mem_total_gib() { awk '/^MemTotal:/ {printf "%d", $2/1024/1024}' /proc/meminfo; }
disk_avail_gib() { df -BG --output=avail "$1" 2>/dev/null | tail -n1 | tr -dc '0-9'; }

# kolla-ansible 은 내부에서 ansible-playbook 등을 PATH 로 찾는다. activate 대신 이 스크립트 프로세스 안에서만 PATH 를 맞춘다.
use_kolla_venv() { export VIRTUAL_ENV="$KOLLA_VENV"; export PATH="$KOLLA_VENV/bin:$PATH"; }

# 진단 안내 한 줄: hint <증상> <가능한 원인과 조치>
hint() { _emit "$_C_YEL" DIAG "$1 -> $2"; }

# venv 안의 도구는 activate 가 아니라 경로로 직접 호출한다.
venv_py() { echo "$KOLLA_VENV/bin/python"; }
venv_pkg_version() { "$(venv_py)" -m pip show "$1" 2>/dev/null | awk '/^Version:/ {print $2}' || true; }

# tool_version <kubectl|terraform|kind|clusterctl>
#   설치된 도구의 버전(앞의 v 제거)을 출력한다. 없으면 빈 문자열. 항상 종료 코드 0.
tool_version() {
  case "$1" in
    kubectl)    kubectl version --client 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | tr -d 'v' || true ;;
    terraform)  terraform version 2>/dev/null | sed -n '1s/^Terraform v//p' || true ;;
    kind)       kind version 2>/dev/null | awk '{print $2}' | head -n1 | tr -d 'v' || true ;;
    clusterctl) clusterctl version -o short 2>/dev/null | head -n1 | tr -d 'v ' || true ;;
    *)          return 0 ;;
  esac
}

# 공통 옵션 처리: --dry-run, --yes, -h/--help. 인식하지 못한 옵션은 종료 코드 3.
kit_parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) KIT_DRY_RUN=1 ;;
      --yes|-y)  KIT_ASSUME_YES=1 ;;
      -h|--help) kit_usage; exit "$EXIT_OK" ;;
      *) echo "알 수 없는 옵션: $arg" >&2; kit_usage >&2; exit "$EXIT_USAGE" ;;
    esac
  done
}
kit_usage() {
  cat <<EOF
사용법: $0 [--dry-run] [--yes]
  --dry-run  변경 없이 실행 계획만 출력
  --yes      확인 질문 없이 진행 (무인 실행용)
환경변수: KIT_LOG_DIR(로그 폴더), KIT_ASSUME_YES=1, KIT_DRY_RUN=1
EOF
}
