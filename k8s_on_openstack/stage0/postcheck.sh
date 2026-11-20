#!/usr/bin/env bash
# stage0/postcheck.sh — 0단계 설치 후 점검.
# 1단계(Kolla-Ansible 배포)로 넘길 산출물이 갖춰졌는지 O/X로 판정한다. 읽기 전용.
# 산출물: 활성화 가능한 $KOLLA_VENV, $KOLLA_CONFIG_DIR/{globals.yml,passwords.yml}, $KOLLA_INVENTORY, 도구 4종(kubectl, terraform, kind, clusterctl).
# Docker 설치와 docker 그룹은 1단계 산출물이므로 여기서 점검하지 않는다.
# 비밀번호 값은 읽지도 출력하지도 않는다(빈 줄 수와 권한만 본다).
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage0 postcheck

PY="$(venv_py)"
PW_FILE="$KOLLA_CONFIG_DIR/passwords.yml"

log_info "0단계 설치 후 점검을 시작합니다 (로그: $KIT_LOG_FILE)"

# ---------------------------------------------------------------- 계정
if [[ "$(id -u)" -ne 0 ]]; then
  check_ok "root 가 아닌 일반 계정"
else
  check_ng "root 가 아닌 일반 계정" "일반 계정" "root" "root 로 설치하면 venv, /etc/kolla 소유권이 어긋난다"
fi

# ---------------------------------------------------------------- 가상환경과 파이썬 패키지
if [[ -x "$PY" ]]; then
  check_ok "Kolla 가상환경" "$KOLLA_VENV"
else
  check_ng "Kolla 가상환경" "$PY 실행 가능" "없음" "install.sh 의 venv 단계가 실행되지 않았다"
fi

# 패키지 버전 비교용 보조 함수: <항목명> <패키지> <기대 버전>
check_pkg() {
  local label="$1" pkg="$2" want="$3" cur
  cur="$(venv_pkg_version "$pkg")"
  if [[ "$cur" == "$want" ]]; then
    check_ok "$label" "$cur"
  else
    check_ng "$label" "$want" "${cur:-없음}" "versions.env 와 설치 버전이 다르다. 'bash stage0/install.sh' 를 다시 실행"
  fi
}
check_pkg "ansible-core 버전" ansible-core "$ANSIBLE_CORE_VERSION"
check_pkg "kolla-ansible 버전" kolla-ansible "$KOLLA_ANSIBLE_VERSION"
check_pkg "venv docker 모듈" docker "$DOCKER_PY_VERSION"
check_pkg "venv dbus-python" dbus-python "$DBUS_PYTHON_VERSION"
check_pkg "python-openstackclient 버전" python-openstackclient "$OPENSTACKCLIENT_VERSION"
check_pkg "openstacksdk 버전" openstacksdk "$OPENSTACKSDK_VERSION"

if [[ -x "$PY" ]] && "$PY" -m pip check >/dev/null 2>&1; then
  check_ok "pip check (의존성 충돌 없음)"
else
  check_ng "pip check (의존성 충돌 없음)" "충돌 없음" "충돌 또는 venv 없음" "'$PY -m pip check' 출력 확인"
fi

if [[ -x "$KOLLA_VENV/bin/openstack" ]]; then
  ocv="$("$KOLLA_VENV/bin/openstack" --version 2>&1 | awk '{print $2}' | head -n1 || true)"
  if [[ "$ocv" == "$OPENSTACKCLIENT_VERSION" ]]; then
    check_ok "openstack CLI 실행" "$ocv"
  else
    check_ng "openstack CLI 실행" "openstack $OPENSTACKCLIENT_VERSION" "${ocv:-실행 실패}" \
      "openstacksdk 4.23.0 은 'Could not read clouds.yaml configuration file' 로 실패한다. ${OPENSTACKSDK_VERSION} 로 고정"
  fi
else
  check_ng "openstack CLI 실행" "$KOLLA_VENV/bin/openstack" "없음" "python-openstackclient 가 설치되지 않았다"
fi

if "$KOLLA_VENV/bin/ansible-galaxy" collection list 2>/dev/null | grep -q 'openstack\.kolla'; then
  check_ok "Ansible Galaxy 의존성(openstack.kolla)"
else
  check_ng "Ansible Galaxy 의존성(openstack.kolla)" "컬렉션 설치됨" "없음" "'kolla-ansible install-deps' 가 실행되지 않았거나 Galaxy 접속 실패"
fi

# ---------------------------------------------------------------- /etc/kolla 산출물
[[ -f "$KOLLA_CONFIG_DIR/globals.yml" ]] \
  && check_ok "globals.yml 존재" \
  || check_ng "globals.yml 존재" "$KOLLA_CONFIG_DIR/globals.yml" "없음" "예제 설정 복사 단계가 실행되지 않았다(수동 구축에서 겪은 'passwords file missing' 의 원인)"

[[ -f "$KOLLA_INVENTORY" ]] \
  && check_ok "인벤토리 존재" "$KOLLA_INVENTORY" \
  || check_ng "인벤토리 존재" "$KOLLA_INVENTORY" "없음" "all-in-one 인벤토리 복사 단계가 실행되지 않았다"

if [[ -f "$PW_FILE" ]]; then
  perm="$(stat -c %a "$PW_FILE")"
  owner="$(stat -c %U "$PW_FILE")"
  empty="$(grep -cE '^[A-Za-z0-9_]+:[[:space:]]*$' "$PW_FILE" || true)"
  [[ "$perm" == "600" ]] \
    && check_ok "passwords.yml 권한 600" \
    || check_ng "passwords.yml 권한 600" "600" "$perm" "'chmod 600 $PW_FILE'. 'world-readable' 경고가 나온다"
  [[ "$owner" == "$(id -un)" ]] \
    && check_ok "passwords.yml 소유자" "$owner" \
    || check_ng "passwords.yml 소유자" "$(id -un)" "$owner" "'sudo chown $(id -un) $PW_FILE'"
  if [[ "$empty" -le "$PASSWORDS_EMPTY_LINE_MAX" ]]; then
    check_ok "passwords.yml 값 생성됨" "빈 줄 ${empty}개 <= ${PASSWORDS_EMPTY_LINE_MAX} (생성 후에는 *_key 묶음 줄만 남는다)"
  else
    check_ng "passwords.yml 값 생성됨" "빈 줄 <= ${PASSWORDS_EMPTY_LINE_MAX}" "${empty}" "kolla-genpwd 가 실행되지 않았다"
  fi
else
  check_ng "passwords.yml 존재" "$PW_FILE" "없음" "예제 설정 복사와 kolla-genpwd 가 필요하다"
fi

# ---------------------------------------------------------------- 도구 바이너리
check_tool() {   # <도구> <기대 버전>
  local tool="$1" want="$2" cur
  cur="$(tool_version "$tool")"
  if [[ "$cur" == "$want" ]]; then
    check_ok "$tool 버전" "$cur"
  else
    check_ng "$tool 버전" "$want" "${cur:-없음}" "versions.env 와 설치 버전이 다르다. 교체하려면 'FORCE_REINSTALL=1 bash stage0/install.sh'"
  fi
}
check_tool kubectl    "$KUBECTL_VERSION"
check_tool terraform  "$TERRAFORM_VERSION"
check_tool kind       "$KIND_VERSION"
check_tool clusterctl "$CLUSTERCTL_VERSION"

report_summary || die "점검 실패. 위 [FAIL] 항목을 해결한 뒤 다시 실행하세요." "$EXIT_FAIL"
log_done "0단계 설치 후 점검 통과"
