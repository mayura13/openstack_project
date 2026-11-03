#!/usr/bin/env bash
# ==============================================================
# stage4/preflight.sh - [4단계] 선행 요소 준비 전 점검
# ==============================================================
# OpenStack을 올리기 전에 Kubernetes가 준비되었는지 확인합니다.
#   kubectl / helm 설치 / Kubernetes API 응답 / 노드 4대 Ready / Kubespray 폴더와 버전 / 4단계 설정 파일 2개
# stage4/prepare.sh 가 가장 먼저 자동으로 실행합니다. 아무것도 바꾸지 않아 안전합니다.
# 실패하면: [FAIL] 항목을 확인하세요. 노드가 Ready가 아니면 3단계(Kubernetes 설치) 결과부터 점검합니다.
# set -u : 정의하지 않은 변수를 쓰면 오류로 멈춥니다. (끝까지 점검하려고 set -e는 쓰지 않음)
set -u

# ROOT_DIR : 프로젝트 맨 위 폴더의 절대 경로 / STAGE4_DIR : stage4 폴더
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE4_DIR="${ROOT_DIR}/stage4"

PASS=0
FAIL=0

# check "이름" 명령... : 명령을 실행해서 성공하면 [PASS], 실패하면 [FAIL]을 출력합니다.
#   shift : 첫 번째 값(이름)을 꺼내고 나머지를 "실행할 명령"으로 씁니다.
#   "$@"  : 남은 값 전체(명령과 그 옵션들)를 그대로 실행합니다.
#   >/dev/null 2>&1 : 명령 자체의 출력은 화면에 보이지 않게 버립니다.
check() {
    local name="$1"
    shift

    if "$@" >/dev/null 2>&1; then
        echo "[PASS] ${name}"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] ${name}"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Stage 4 Preflight ==="

# command -v 도구 : 도구가 설치되어 있는지 확인합니다.
check "kubectl is available" command -v kubectl
check "Helm is available" command -v helm

# kubectl get nodes 가 성공하면 Kubernetes API가 응답하는 것입니다. (~/.kube/config 가 필요: prepare.sh 에서 만듭니다)
check "Kubernetes API is reachable" \
    kubectl get nodes

# Ready 상태 노드가 정확히 4개인지 확인합니다. bash -c '...' 는 작은 쉘을 하나 띄워 그 안의 명령을 실행합니다.
# '\'' 는 "작은따옴표 안에서 작은따옴표 문자를 쓰기 위한" 쉘 문법 기교입니다.
check "All 4 Kubernetes nodes are Ready" \
    bash -c '[ "$(kubectl get nodes --no-headers 2>/dev/null | awk '\''$2=="Ready"{n++} END{print n+0}'\'')" -eq 4 ]'

check "Kubespray repository exists" \
    test -d "${HOME}/kubespray/.git"

# Kubespray 폴더의 태그 이름이 v2.31.0 과 정확히 같은지 (--exact-match). 버전은 이곳에 직접 적혀 있습니다.
check "Kubespray version is v2.31.0" \
    bash -c '[ "$(git -C "$HOME/kubespray" describe --tags --exact-match 2>/dev/null)" = "v2.31.0" ]'

# stage4/config/addons.yml (스토리지 설정) 파일이 있는지
check "Stage 4 addon configuration exists" \
    test -f "${STAGE4_DIR}/config/addons.yml"

check "OpenStack-Helm version configuration exists" \
    test -f "${STAGE4_DIR}/chart-versions.env"

echo
echo "Preflight result: ${PASS} PASS / ${FAIL} FAIL"

# 실패가 하나라도 있으면 종료 코드 1로 끝납니다.
if [ "${FAIL}" -ne 0 ]; then
    exit 1
fi
