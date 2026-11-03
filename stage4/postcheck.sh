#!/usr/bin/env bash
# ==============================================================
# stage4/postcheck.sh - [4단계] 선행 요소 준비 결과 점검
# ==============================================================
# 확인 항목 11개
#   Kubernetes API / openstack 네임스페이스 / 노드 라벨(ctrl-worker, compute-1, compute-2) /
#   general 스토리지클래스(local-path 사용) / local-path Pod 동작 / Helm 저장소 / osh 플러그인 / OpenStack-Helm 커밋
# make stage-4 의 마지막 단계입니다. 실패하면 [FAIL] 항목에 해당하는 4단계 스크립트를 다시 실행해 보세요.
# set -u : 정의하지 않은 변수를 쓰면 오류로 멈춥니다. (끝까지 점검하려고 set -e는 쓰지 않음)
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE4_DIR="${ROOT_DIR}/stage4"

# chart-versions.env 에서 고정한 OpenStack-Helm 커밋(OSH_COMMIT)을 불러옵니다.
source "${STAGE4_DIR}/chart-versions.env"

PASS=0
FAIL=0

# check "이름" 명령... : 명령이 성공하면 [PASS], 실패하면 [FAIL]을 출력합니다. ("$@" 는 넘겨받은 명령 전체)
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

echo "=== Stage 4 Post-check ==="

# 1. Kubernetes access
check "Kubernetes API is reachable" \
    kubectl get nodes

# 2. OpenStack namespace
# jsonpath : kubectl 출력에서 필요한 값 하나만 골라내는 표현입니다. {.status.phase} 는 네임스페이스의 상태값입니다. (Active 여야 정상)
check "openstack namespace is Active" \
    bash -c '[ "$(kubectl get namespace openstack -o jsonpath="{.status.phase}" 2>/dev/null)" = "Active" ]'

# 3. ctrl-worker labels
# 노드 라벨 확인: configure-nodes.sh 가 붙인 라벨 값이 enabled 인지 jsonpath 로 읽어서 비교합니다. (compute-1, compute-2 도 같은 방식)
check "ctrl-worker has OpenStack control-plane labels" \
    bash -c '[ "$(kubectl get node ctrl-worker -o jsonpath="{.metadata.labels.openstack-control-plane}" 2>/dev/null)" = "enabled" ] && [ "$(kubectl get node ctrl-worker -o jsonpath="{.metadata.labels.openvswitch}" 2>/dev/null)" = "enabled" ]'

# 4. compute-1 labels
check "compute-1 has OpenStack compute labels" \
    bash -c '[ "$(kubectl get node compute-1 -o jsonpath="{.metadata.labels.openstack-compute-node}" 2>/dev/null)" = "enabled" ] && [ "$(kubectl get node compute-1 -o jsonpath="{.metadata.labels.openvswitch}" 2>/dev/null)" = "enabled" ]'

# 5. compute-2 labels
check "compute-2 has OpenStack compute labels" \
    bash -c '[ "$(kubectl get node compute-2 -o jsonpath="{.metadata.labels.openstack-compute-node}" 2>/dev/null)" = "enabled" ] && [ "$(kubectl get node compute-2 -o jsonpath="{.metadata.labels.openvswitch}" 2>/dev/null)" = "enabled" ]'

# 6. general StorageClass
# general 이라는 이름의 스토리지클래스(PVC가 볼륨을 받는 방식 정의)가 있는지
check "general StorageClass exists" \
    kubectl get storageclass general

# 7. general uses local-path
# 그 스토리지클래스가 local-path(노드 로컬 디스크 사용) 방식인지 provisioner 이름으로 확인합니다.
check "general uses rancher.io/local-path" \
    bash -c '[ "$(kubectl get storageclass general -o jsonpath="{.provisioner}" 2>/dev/null)" = "rancher.io/local-path" ]'

# 8. local-path provisioner is Running
# local-path 를 실제로 처리하는 Pod(local-path-provisioner-...)가 Running 인지. (awk 로 이름과 상태 열을 확인)
check "local-path provisioner is Running" \
    bash -c 'kubectl get pods -n local-path-storage --no-headers 2>/dev/null | awk '\''$1 ~ /^local-path-provisioner-/ && $3=="Running" {found=1} END {exit !found}'\'''

# 9. OpenStack-Helm repository
# helm repo list 에서 openstack-helm 저장소와 주소가 맞는지 확인합니다.
check "OpenStack-Helm Helm repository exists" \
    bash -c 'helm repo list 2>/dev/null | awk '\''NR>1 && $1=="openstack-helm" && $2=="https://tarballs.opendev.org/openstack/openstack-helm" {found=1} END {exit !found}'\'''

# 10. osh plugin
# helm plugin list 에서 osh 플러그인이 있는지 확인합니다.
check "osh Helm plugin is available" \
    bash -c 'helm plugin list 2>/dev/null | awk '\''NR>1 && $1=="osh" {found=1} END {exit !found}'\'''

# 11. OpenStack-Helm source commit
# ~/openstack-helm 의 Git 커밋이 고정한 값(OSH_COMMIT)과 같은지 확인합니다.
# '"${OSH_COMMIT}"' 는 작은따옴표 밖으로 잠깐 나와서 변수 값을 끼워 넣는 쉘 기교입니다.
check "OpenStack-Helm source matches pinned commit" \
    bash -c '[ -d "$HOME/openstack-helm/.git" ] && [ "$(git -C "$HOME/openstack-helm" rev-parse HEAD 2>/dev/null)" = "'"${OSH_COMMIT}"'" ]'

echo
echo "Post-check result: ${PASS} PASS / ${FAIL} FAIL"

# 실패가 하나라도 있으면 종료 코드 1로 끝납니다.
if [ "${FAIL}" -ne 0 ]; then
    exit 1
fi
