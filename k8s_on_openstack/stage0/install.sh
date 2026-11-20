#!/usr/bin/env bash
# stage0/install.sh — 0단계 도구 설치.
#
# 모든 단계는 멱등이다. 이미 충족된 단계는 건너뛰고, 필요한 단계만 계획으로 출력한 뒤 실행한다.
#   --dry-run  변경 없이 "무엇을 건너뛰고 무엇을 실행할지"만 출력 (서버에서 먼저 돌려 보기를 권장)
#   --yes      호스트 변경 확인 질문 없이 진행
#
# 수동 구축에서 얻은 규칙
#  - venv 는 activate 하지 않고 경로($KOLLA_VENV/bin/...)로 직접 호출한다.
#  - kolla-genpwd 는 이미 값이 채워진 passwords.yml 에 다시 실행하지 않는다(덮어쓰기 여부 미확인).
#  - /etc/kolla 복사는 기존 파일을 덮어쓰지 않는다(cp -n).
#  - 이미 설치된 도구의 버전이 다르면 덮어쓰지 않고 경고한다. 교체하려면 FORCE_REINSTALL=1.
#  - Docker 설치(bootstrap-servers)와 docker 그룹 추가는 0단계가 아니라 1단계에서 한다.
#    수동 구축 history 에서 bootstrap-servers 는 "# MANUAL 1" 구간에 있었고, docker 그룹은 3단계에서 추가했다.
#    따라서 0단계는 그룹을 바꾸지 않으며 재접속(종료 코드 2)이 필요 없다.
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage0 install
use_kolla_venv   # kolla-ansible install-deps 등이 PATH 로 ansible-galaxy 를 찾는다

: "${FORCE_REINSTALL:=0}"
PY="$(venv_py)"
PW_FILE="$KOLLA_CONFIG_DIR/passwords.yml"
APT_PKGS=(git python3-dev python3-venv libffi-dev gcc libssl-dev libdbus-glib-1-dev curl unzip ca-certificates)

KIT_TMP=""
trap '[[ -n "$KIT_TMP" ]] && rm -rf "$KIT_TMP"' EXIT
tmpdir() { [[ -n "$KIT_TMP" ]] || KIT_TMP="$(mktemp -d)"; echo "$KIT_TMP"; }

# 파이썬 패키지 고정 목록: "패키지명==버전"
PYEXTRA_SPECS=(
  "docker==${DOCKER_PY_VERSION}"
  "dbus-python==${DBUS_PYTHON_VERSION}"
  "python-openstackclient==${OPENSTACKCLIENT_VERSION}"
  "openstacksdk==${OPENSTACKSDK_VERSION}"
)

# ------------------------------------------------------------------ 보조 함수
SUDO_APT=(sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a)

fetch()         { curl -fsSL --retry 3 --retry-delay 2 -m 900 -o "$2" "$1"; }
verify_sha256() { echo "$2  $1" | sha256sum -c --status; }   # <파일> <기대 해시>

pw_empty_lines() {
  [[ -f "$PW_FILE" ]] || { echo -1; return 0; }
  grep -cE '^[A-Za-z0-9_]+:[[:space:]]*$' "$PW_FILE" || true
}

# ------------------------------------------------------------------ 단계 정의
# need_<id>  : 실행이 필요하면 0, 이미 충족이면 1. 어느 쪽이든 REASON 에 이유를 남긴다.
# do_<id>    : 실제 실행.
STEPS=(apt venv ansible kolla pyextras kolla_dirs galaxy passwords bin_kubectl bin_terraform bin_kind bin_clusterctl)
declare -A TITLE=(
  [apt]="필수 apt 패키지"
  [venv]="Kolla 가상환경($KOLLA_VENV)"
  [ansible]="ansible-core ${ANSIBLE_CORE_VERSION}"
  [kolla]="kolla-ansible ${KOLLA_ANSIBLE_VERSION}"
  [pyextras]="venv 파이썬 패키지(docker, dbus-python, openstackclient, openstacksdk)"
  [kolla_dirs]="${KOLLA_CONFIG_DIR} 설정 파일과 인벤토리(${KOLLA_INVENTORY})"
  [galaxy]="Ansible Galaxy 의존성(kolla-ansible install-deps)"
  [passwords]="passwords.yml 생성과 권한 600"
  [bin_kubectl]="kubectl ${KUBECTL_VERSION}"
  [bin_terraform]="terraform ${TERRAFORM_VERSION}"
  [bin_kind]="kind ${KIND_VERSION}"
  [bin_clusterctl]="clusterctl ${CLUSTERCTL_VERSION}"
)
REASON=""
MISSING_APT=()
PYEXTRA_TODO=()

need_apt() {
  MISSING_APT=()
  local p
  for p in "${APT_PKGS[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || MISSING_APT+=("$p")
  done
  if [[ "${#MISSING_APT[@]}" -gt 0 ]]; then REASON="없음: ${MISSING_APT[*]}"; return 0; fi
  REASON="모두 설치됨"; return 1
}
do_apt() {
  run_step "apt update" "${SUDO_APT[@]}" apt-get update
  run_step "apt install ${MISSING_APT[*]}" "${SUDO_APT[@]}" apt-get install -y "${MISSING_APT[@]}"
}

need_venv() {
  if [[ -x "$PY" ]]; then REASON="있음"; return 1; fi
  REASON="$KOLLA_VENV 없음"; return 0
}
do_venv() {
  run_step "venv 생성" python3 -m venv "$KOLLA_VENV"
  run_step "pip 업그레이드" "$PY" -m pip install -U pip
}

need_ansible() {
  local cur; cur="$(venv_pkg_version ansible-core)"
  if [[ "$cur" == "$ANSIBLE_CORE_VERSION" ]]; then REASON="현재 $cur"; return 1; fi
  REASON="현재 ${cur:-없음} -> ${ANSIBLE_CORE_VERSION}"; return 0
}
do_ansible() { run_step "ansible-core 설치" "$PY" -m pip install "ansible-core==${ANSIBLE_CORE_VERSION}"; }

need_kolla() {
  local cur; cur="$(venv_pkg_version kolla-ansible)"
  if [[ "$cur" == "$KOLLA_ANSIBLE_VERSION" ]]; then REASON="현재 $cur"; return 1; fi
  REASON="현재 ${cur:-없음} -> ${KOLLA_ANSIBLE_VERSION}"; return 0
}
do_kolla() {
  run_step "kolla-ansible 설치(태그 고정)" "$PY" -m pip install "git+https://opendev.org/openstack/kolla-ansible@${KOLLA_ANSIBLE_VERSION}"
}

need_pyextras() {
  PYEXTRA_TODO=()
  local spec name want cur
  for spec in "${PYEXTRA_SPECS[@]}"; do
    name="${spec%%==*}"; want="${spec##*==}"
    cur="$(venv_pkg_version "$name")"
    [[ "$cur" == "$want" ]] || PYEXTRA_TODO+=("$spec")
  done
  if [[ "${#PYEXTRA_TODO[@]}" -gt 0 ]]; then REASON="설치 또는 교체: ${PYEXTRA_TODO[*]}"; return 0; fi
  REASON="모두 고정 버전과 일치"; return 1
}
do_pyextras() {
  # prechecks 가 docker 모듈을 요구한다(수동 구축 1단계 오류 1번). 여기서 미리 넣는다.
  run_step "venv 파이썬 패키지 설치" "$PY" -m pip install "${PYEXTRA_SPECS[@]}"
  run_step "pip check" "$PY" -m pip check
}

need_kolla_dirs() {
  local miss=()
  [[ -d "$KOLLA_CONFIG_DIR" ]]              || miss+=("$KOLLA_CONFIG_DIR")
  [[ -f "$KOLLA_CONFIG_DIR/globals.yml" ]]  || miss+=("globals.yml")
  [[ -f "$PW_FILE" ]]                       || miss+=("passwords.yml")
  [[ -f "$KOLLA_INVENTORY" ]]               || miss+=("$KOLLA_INVENTORY")
  if [[ -d "$KOLLA_CONFIG_DIR" && ! -O "$KOLLA_CONFIG_DIR" ]]; then miss+=("소유자가 ${USER:-$(id -un)} 가 아님"); fi
  if [[ "${#miss[@]}" -gt 0 ]]; then REASON="없거나 어긋남: ${miss[*]}"; return 0; fi
  REASON="모두 있음"; return 1
}
do_kolla_dirs() {
  local ex="$KOLLA_VENV/share/kolla-ansible"
  [[ -d "$ex/etc_examples/kolla" ]] || die "예제 설정을 찾을 수 없습니다: $ex/etc_examples/kolla (kolla-ansible 설치 단계가 먼저 필요합니다)"
  run_step "/etc/kolla 생성과 소유권" bash -c "sudo mkdir -p '$KOLLA_CONFIG_DIR' && sudo chown '$(id -un):$(id -gn)' '$KOLLA_CONFIG_DIR'"
  # -n: 기존 파일은 덮어쓰지 않는다
  run_step "예제 설정 복사(덮어쓰지 않음)" cp -rn "$ex/etc_examples/kolla/." "$KOLLA_CONFIG_DIR/"
  if [[ ! -f "$KOLLA_INVENTORY" ]]; then
    run_step "all-in-one 인벤토리 복사" cp "$ex/ansible/inventory/all-in-one" "$KOLLA_INVENTORY"
  fi
}

need_galaxy() {
  if "$KOLLA_VENV/bin/ansible-galaxy" collection list 2>/dev/null | grep -q 'openstack\.kolla'; then
    REASON="openstack.kolla 컬렉션 있음"; return 1
  fi
  REASON="컬렉션 없음"; return 0
}
do_galaxy() { run_step "kolla-ansible install-deps" "$KOLLA_VENV/bin/kolla-ansible" install-deps; }

need_passwords() {
  local n perm; n="$(pw_empty_lines)"
  perm="$(stat -c %a "$PW_FILE" 2>/dev/null || echo none)"
  if [[ "$n" -lt 0 ]]; then REASON="passwords.yml 없음(kolla_dirs 단계 후 생성)"; return 0; fi
  if [[ "$n" -gt "$PASSWORDS_EMPTY_LINE_MAX" ]]; then REASON="값이 빈 줄 ${n}개 -> kolla-genpwd 필요"; return 0; fi
  if [[ "$perm" != "600" ]]; then REASON="값은 채워짐, 권한 ${perm} -> 600"; return 0; fi
  REASON="값 채워짐(빈 줄 ${n}개), 권한 600. kolla-genpwd 는 다시 실행하지 않음"; return 1
}
do_passwords() {
  local n; n="$(pw_empty_lines)"
  if [[ "$n" -gt "$PASSWORDS_EMPTY_LINE_MAX" ]]; then
    run_step "kolla-genpwd" "$KOLLA_VENV/bin/kolla-genpwd"
  else
    log_info "passwords.yml 에 이미 값이 있어 kolla-genpwd 를 다시 실행하지 않습니다."
  fi
  run_step "passwords.yml 권한 600" chmod 600 "$PW_FILE"
}

# --- 바이너리: 설치돼 있고 버전이 다르면 덮어쓰지 않고 경고한다(FORCE_REINSTALL=1 로 교체).
need_bin() {   # <도구> <기대 버전>
  local tool="$1" want="$2" cur; cur="$(tool_version "$tool")"
  if [[ "$cur" == "$want" ]]; then REASON="현재 $cur"; return 1; fi
  if [[ -n "$cur" && "$FORCE_REINSTALL" != "1" ]]; then
    REASON="다른 버전 $cur 설치됨(기대 $want). 덮어쓰지 않음. 교체하려면 FORCE_REINSTALL=1"
    check_warn "$tool 버전 불일치" "현재 $cur, 기대 $want"
    return 1
  fi
  REASON="현재 ${cur:-없음} -> ${want}"; return 0
}
need_bin_kubectl()    { need_bin kubectl    "$KUBECTL_VERSION"; }
need_bin_terraform()  { need_bin terraform  "$TERRAFORM_VERSION"; }
need_bin_kind()       { need_bin kind       "$KIND_VERSION"; }
need_bin_clusterctl() { need_bin clusterctl "$CLUSTERCTL_VERSION"; }

install_bin() { run_step "$1 설치($BIN_DIR)" sudo install -m 0755 "$2" "$BIN_DIR/$1"; }

do_bin_kubectl() {
  local d url="https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  d="$(tmpdir)"
  run_step "kubectl 다운로드" fetch "$url" "$d/kubectl"
  run_step "kubectl 체크섬 파일 다운로드" fetch "${url}.sha256" "$d/kubectl.sha256"
  run_step "kubectl sha256 검증" verify_sha256 "$d/kubectl" "$(cut -d' ' -f1 "$d/kubectl.sha256")"
  install_bin kubectl "$d/kubectl"
}

do_bin_terraform() {
  local d base="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}"
  local zip="terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
  d="$(tmpdir)"
  run_step "terraform 다운로드" fetch "$base/$zip" "$d/$zip"
  run_step "terraform SHA256SUMS 다운로드" fetch "$base/terraform_${TERRAFORM_VERSION}_SHA256SUMS" "$d/SHA256SUMS"
  run_step "terraform sha256 검증" bash -c "cd '$d' && grep ' $zip\$' SHA256SUMS | sha256sum -c --status"
  run_step "terraform 압축 해제" unzip -o -q "$d/$zip" -d "$d/tf"
  install_bin terraform "$d/tf/terraform"
}

do_bin_kind() {
  local d; d="$(tmpdir)"
  run_step "kind 다운로드" fetch "https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-linux-amd64" "$d/kind"
  if [[ -n "$KIND_SHA256" ]]; then run_step "kind sha256 검증" verify_sha256 "$d/kind" "$KIND_SHA256"
  else check_warn "kind 체크섬 미검증" "versions.env 의 KIND_SHA256 이 비어 있음"; fi
  install_bin kind "$d/kind"
}

do_bin_clusterctl() {
  local d; d="$(tmpdir)"
  run_step "clusterctl 다운로드" fetch "https://github.com/kubernetes-sigs/cluster-api/releases/download/v${CLUSTERCTL_VERSION}/clusterctl-linux-amd64" "$d/clusterctl"
  if [[ -n "$CLUSTERCTL_SHA256" ]]; then run_step "clusterctl sha256 검증" verify_sha256 "$d/clusterctl" "$CLUSTERCTL_SHA256"
  else check_warn "clusterctl 체크섬 미검증" "versions.env 의 CLUSTERCTL_SHA256 이 비어 있음"; fi
  install_bin clusterctl "$d/clusterctl"
}

# ------------------------------------------------------------------ 계획 수립
log_info "0단계 도구 설치 계획을 세웁니다 (로그: $KIT_LOG_FILE)"
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
  log_done "설치할 것이 없습니다. 모든 항목이 이미 충족되어 있습니다."
elif [[ "$KIT_DRY_RUN" == "1" ]]; then
  log_info "(dry-run) 위 [실행 예정] ${#PLAN[@]}개 단계만 실제 실행 시 변경됩니다. 아무것도 바꾸지 않고 종료합니다."
  report_summary || true
  exit "$EXIT_OK"
else
  sudo_nopass || die "sudo 를 비밀번호 없이 쓸 수 없습니다. 'sudo -n true' 가 성공해야 합니다." "$EXIT_FAIL"
  impact="${#PLAN[@]}개 단계 실행 (패키지 설치, 파이썬 가상환경, ${KOLLA_CONFIG_DIR} 설정, ${BIN_DIR} 에 도구 설치)"
  confirm "$impact" "단계별 수동 복구. 자동 복구는 제공하지 않음(로그: $KIT_LOG_FILE)"
fi

# ------------------------------------------------------------------ 실행
for id in "${PLAN[@]}"; do
  log_step "== ${TITLE[$id]}"
  "do_$id"
done

report_summary || true
log_done "0단계 도구 설치 완료"
