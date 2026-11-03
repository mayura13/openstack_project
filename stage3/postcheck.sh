#!/usr/bin/env bash
# ==============================================================
# stage3/postcheck.sh - [3단계] Kubernetes 설치 결과 점검
# ==============================================================
# 컨트롤 플레인(cp) 노드에 SSH로 접속해서 kubectl 로 클러스터 상태를 확인합니다.
#   SSH 접속 / API 응답 / 노드 4대 / 모두 Ready / 버전 v1.35.4 / 노드 이름 / kube-system Pod 정상 / containerd 런타임
# make stage-3 의 마지막 단계입니다. 실패하면 [FAIL] 항목의 설명대로 확인하고, 필요하면 deploy 로그를 봅니다.
# set -u : 정의하지 않은 변수를 쓰면 오류로 멈춥니다. (끝까지 점검하려고 set -e는 쓰지 않음)
set -u

# CONTROL_PLANE : cp 노드 IP (Terraform 설정과 같은 값을 직접 적었습니다)
# SSH_KEY       : VM 접속용 개인 키
# EXPECTED_VERSION : 기대하는 Kubernetes 버전 (versions.env 와 같은 값을 직접 적었습니다)
CONTROL_PLANE="192.168.100.10"
SSH_KEY="${HOME}/.ssh/id_vm_ed25519"
EXPECTED_VERSION="v1.35.4"

PASS=0
FAIL=0

pass() {
    echo "[PASS] $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "[FAIL] $1"
    FAIL=$((FAIL + 1))
}

# remote "명령" : cp 노드에서 명령을 실행하고 결과를 가져옵니다.
#   -i 키                       : 이 키로 접속
#   -o IdentitiesOnly=yes       : 지정한 키만 사용 (다른 키를 시도하지 않음)
#   -o StrictHostKeyChecking=no : 처음 보는 서버의 지문 확인 질문을 건너뜀 (VM을 자주 다시 만들기 때문)
#   kit@IP                      : kit 계정으로 cp 접속
remote() {
    ssh \
        -i "${SSH_KEY}" \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no \
        "kit@${CONTROL_PLANE}" "$1"
}

echo "========================================"
echo " Stage 3 - Kubernetes Postcheck"
echo "========================================"

# 1. Control-plane SSH
# cp 노드에 SSH로 접속되는지 (true 는 아무 일도 안 하고 성공하는 명령)
if remote "true" >/dev/null 2>&1; then
    pass "Control-plane SSH connectivity"
else
    fail "Control-plane SSH connectivity"
fi

# 2. Kubernetes API
# sudo kubectl get nodes 가 성공하면 Kubernetes API 서버가 응답하는 것입니다.
if remote "sudo kubectl get nodes" >/dev/null 2>&1; then
    pass "Kubernetes API reachable"
else
    fail "Kubernetes API unreachable"
fi

# 3. Node count
# 노드 수 세기. --no-headers 는 제목 줄을 빼고 출력하고 wc -l 은 줄 수를 셉니다. 실패하면 0으로 처리합니다. (|| echo 0)
NODE_COUNT="$(remote "sudo kubectl get nodes --no-headers 2>/dev/null | wc -l" 2>/dev/null || echo 0)"

if [[ "${NODE_COUNT}" -eq 4 ]]; then
    pass "Kubernetes node count: 4"
else
    fail "Expected 4 nodes, found ${NODE_COUNT}"
fi

# 4. Ready nodes
# Ready 상태인 노드 수 세기. awk 는 2번째 열($2)이 "Ready"인 줄만 셉니다.
# 문자열 안의 \$2 처럼 \ 를 붙이는 이유: 내 컴퓨터의 쉘이 먼저 해석하지 않고 cp 노드에 그대로 전달하려는 것입니다.
READY_COUNT="$(remote "sudo kubectl get nodes --no-headers 2>/dev/null | awk '\$2 == \"Ready\" {count++} END {print count+0}'" 2>/dev/null || echo 0)"

if [[ "${READY_COUNT}" -eq 4 ]]; then
    pass "All 4 Kubernetes nodes are Ready"
else
    fail "Ready nodes: ${READY_COUNT}/4"
fi

# 5. Kubernetes version
# 각 노드의 kubelet 버전을 모아서 기대하는 버전(v1.35.4)과 같은 노드가 4개인지 확인합니다. (jsonpath: 출력할 값을 골라내는 표현)
VERSION_COUNT="$(remote "sudo kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{\"\\n\"}{end}' 2>/dev/null | grep -cx '${EXPECTED_VERSION}'" 2>/dev/null || true)"
VERSION_COUNT="${VERSION_COUNT:-0}"

if [[ "${VERSION_COUNT}" -eq 4 ]]; then
    pass "All nodes use Kubernetes ${EXPECTED_VERSION}"
else
    fail "Nodes using ${EXPECTED_VERSION}: ${VERSION_COUNT}/4"
fi

# 6. Expected node names
# cp, ctrl-worker, compute-1, compute-2 이름의 노드가 모두 등록되었는지 하나씩 확인합니다.
EXPECTED_NODES=("cp" "ctrl-worker" "compute-1" "compute-2")
MISSING_NODE=0

for node in "${EXPECTED_NODES[@]}"; do
    if ! remote "sudo kubectl get node '${node}'" >/dev/null 2>&1; then
        MISSING_NODE=1
    fi
done

if [[ "${MISSING_NODE}" -eq 0 ]]; then
    pass "Expected node names are present"
else
    fail "One or more expected nodes are missing"
fi

# 7. System pods
# kube-system(Kubernetes 핵심 Pod가 사는 곳)에서 Running/Completed 가 아닌 Pod 수를 셉니다. 0이어야 정상입니다.
NOT_READY_PODS="$(remote "sudo kubectl get pods -n kube-system --no-headers 2>/dev/null | awk '\$3 != \"Running\" && \$3 != \"Completed\" {count++} END {print count+0}'" 2>/dev/null || echo 999)"

if [[ "${NOT_READY_PODS}" -eq 0 ]]; then
    pass "kube-system pods are healthy"
else
    fail "Unhealthy kube-system pods: ${NOT_READY_PODS}"
fi

# 8. Container runtime
# 모든 노드의 컨테이너 런타임이 containerd 인지 확인합니다. (런타임 = 컨테이너를 실제로 실행하는 프로그램)
RUNTIME_COUNT="$(remote "sudo kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.containerRuntimeVersion}{\"\\n\"}{end}' 2>/dev/null | grep -c '^containerd://'" 2>/dev/null || true)"
RUNTIME_COUNT="${RUNTIME_COUNT:-0}"

if [[ "${RUNTIME_COUNT}" -eq 4 ]]; then
    pass "All nodes use containerd"
else
    fail "Nodes using containerd: ${RUNTIME_COUNT}/4"
fi

echo
echo "========================================"
echo " Postcheck result: ${PASS} PASS / ${FAIL} FAIL"
echo "========================================"

# 실패가 하나라도 있으면 종료 코드 1로 끝납니다.
if [[ "${FAIL}" -ne 0 ]]; then
    exit 1
fi
