#!/usr/bin/env bash
# ==============================================================
# evaluation/collect-state.sh - 배포가 끝난 뒤 "최종 상태"를 파일로 저장
# ==============================================================
# Kubernetes와 OpenStack의 최종 상태를 사람이 비교하기 쉬운 텍스트 파일들로 저장합니다.
# 여러 번 배포한 결과를 서로 비교(결과가 매번 같은지 확인)할 때 쓸 수 있습니다. 모든 목록은 정렬(sort)해서 저장합니다.
#
# 사용법: bash evaluation/collect-state.sh <저장 폴더>      예) bash evaluation/collect-state.sh logs/run-01/final-state
#         상대 경로를 주면 프로젝트 맨 위 폴더 기준으로 저장합니다.
# 이 스크립트는 상태를 읽어서 파일로 저장할 뿐, 클러스터 설정을 바꾸지 않습니다. (OpenStack 로그인 토큰 발급은 합니다)
# Makefile에는 연결되어 있지 않습니다.
#
# 저장되는 파일
#   kubernetes-nodes.txt / pod-summary.txt / helm-releases.txt / container-images.txt
#   openstack-services.txt / openstack-endpoints.txt / nova-compute-services.txt
#   placement-resource-providers.txt / placement-resource-provider-count.txt
#   (port-forward-*.log 는 접속용 임시 연결의 로그입니다)
#
# set -euo pipefail : 명령이 하나라도 실패하면 즉시 멈춥니다. (-e 실패 시 중단 / -u 없는 변수 사용 시 중단 / pipefail 파이프 중간 실패도 실패)
set -euo pipefail

# PROJECT_ROOT : 프로젝트 맨 위 폴더의 절대 경로
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 저장 폴더를 정확히 1개 받아야 합니다. ($# 는 인자의 개수) 아니면 사용법을 보여 주고 종료합니다.
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <output-directory>"
    echo "Example: $0 logs/baseline/final-state"
    exit 1
fi

OUTPUT_DIR="$1"

# 저장 폴더가 상대 경로(/ 로 시작하지 않음)면 프로젝트 맨 위 폴더 기준 경로로 바꿉니다.
if [[ "$OUTPUT_DIR" != /* ]]; then
    OUTPUT_DIR="${PROJECT_ROOT}/${OUTPUT_DIR}"
fi

mkdir -p "$OUTPUT_DIR"

echo "[INFO] Collecting final deployment state..."

# --------------------------------------------------
# 1. Kubernetes nodes
# --------------------------------------------------

# Kubernetes 노드 목록(이름, 상태, kubelet 버전)을 저장합니다. custom-columns 는 보여 줄 열을 직접 고르는 옵션입니다.
# ※ STATUS 열은 노드 상태 목록의 마지막 항목의 "종류(type, 보통 Ready)"를 출력합니다.
#   Ready 가 True 인지 False 인지는 이 값으로 알 수 없으므로, 노드가 실제로 Ready 인지는 stage3/postcheck.sh 로 확인하세요.
kubectl get nodes \
    -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,VERSION:.status.nodeInfo.kubeletVersion' \
    --no-headers \
    | sort > "$OUTPUT_DIR/kubernetes-nodes.txt"

# --------------------------------------------------
# 2. Pod state summary by namespace and phase
# --------------------------------------------------

# 모든 네임스페이스의 Pod를 "네임스페이스, 상태" 쌍으로 뽑아서 정렬한 뒤 종류별 개수를 셉니다. (sort | uniq -c)
# 결과 형태: 네임스페이스 [탭] 상태 [탭] 개수
# Pod 이름처럼 매번 달라지는 값은 빼고 개수만 남겨서, 회차끼리 비교하기 쉽게 합니다.
kubectl get pods -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.status.phase}{"\n"}{end}' \
    | sort \
    | uniq -c \
    | awk '{print $2 "\t" $3 "\t" $1}' \
    | sort > "$OUTPUT_DIR/pod-summary.txt"

# --------------------------------------------------
# 3. Helm releases
# --------------------------------------------------

# Helm 릴리스 목록(네임스페이스, 이름, 상태, 차트 이름-버전)을 python3 로 정렬해서 저장합니다.
helm list -A \
    -o json | \
python3 -c '
import json
import sys

releases = json.load(sys.stdin)

for r in sorted(releases, key=lambda x: (x["namespace"], x["name"])):
    print(
        r["namespace"],
        r["name"],
        r["status"],
        r["chart"],
        sep="\t"
    )
' > "$OUTPUT_DIR/helm-releases.txt"

# --------------------------------------------------
# 4. Container images
# --------------------------------------------------

# 클러스터에서 실제로 사용 중인 컨테이너 이미지 목록(중복 제거, 정렬)을 저장합니다. 이미지가 고정된 버전인지 확인하는 용도입니다.
kubectl get pods -A -o json | \
python3 -c '
import json
import sys

data = json.load(sys.stdin)
images = set()

for pod in data.get("items", []):
    for container in (
        pod.get("spec", {}).get("initContainers", [])
        + pod.get("spec", {}).get("containers", [])
    ):
        image = container.get("image")
        if image:
            images.add(image)

for image in sorted(images):
    print(image)
' > "$OUTPUT_DIR/container-images.txt"

echo "[PASS] Kubernetes and Helm state collected"
echo "[INFO] Output: $OUTPUT_DIR"

# --------------------------------------------------
# 5. OpenStack state
# --------------------------------------------------

echo "[INFO] Collecting OpenStack state..."

# OpenStack 상태 수집 시작. openstack 명령은 0단계에서 만든 가상환경의 것을 사용합니다.
OPENSTACK_CLI="${HOME}/venv-openstack/bin/openstack"

if [ ! -x "$OPENSTACK_CLI" ]; then
    echo "[FAIL] OpenStack CLI not found: $OPENSTACK_CLI"
    exit 1
fi

# get_os_secret <키 이름> : Kubernetes Secret(keystone-keystone-admin)에서 관리자 계정 정보 한 항목을 읽습니다. (base64 로 저장되어 있어 -d 로 풂)
get_os_secret() {
    kubectl get secret keystone-keystone-admin \
        -n openstack \
        -o "jsonpath={.data.$1}" | base64 -d
}

# PF_PIDS : 백그라운드로 띄운 port-forward 프로세스 번호(PID) 목록
PF_PIDS=()

# cleanup_port_forwards : 켜 둔 port-forward 프로세스를 모두 종료하는 함수
cleanup_port_forwards() {
    for pid in "${PF_PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
}

# trap ... EXIT : 스크립트가 어떻게 끝나든(성공이든 실패든) 위 정리 함수를 실행하도록 등록합니다.
trap cleanup_port_forwards EXIT

echo "[INFO] Starting OpenStack API port-forwards..."

# kubectl port-forward svc/<서비스> <내 포트>:<서비스 포트> & : 클러스터 안의 API 서비스를 내 서버의 127.0.0.1 포트로 연결합니다. (& = 백그라운드)
#   keystone-api 5000 -> 15000 / nova-api 8774 -> 18774 / placement-api 8778 -> 18778
# "$!" 는 방금 띄운 프로세스 번호(PID)이고 PF_PIDS 에 저장합니다.
kubectl port-forward -n openstack \
    svc/keystone-api 15000:5000 \
    >"$OUTPUT_DIR/port-forward-keystone.log" 2>&1 &
PF_PIDS+=("$!")

kubectl port-forward -n openstack \
    svc/nova-api 18774:8774 \
    >"$OUTPUT_DIR/port-forward-nova.log" 2>&1 &
PF_PIDS+=("$!")

kubectl port-forward -n openstack \
    svc/placement-api 18778:8778 \
    >"$OUTPUT_DIR/port-forward-placement.log" 2>&1 &
PF_PIDS+=("$!")

# port-forward 연결이 준비될 때까지 3초 기다립니다.
sleep 3

# check_api <이름> <주소> : 그 주소에 접속이 되는지 확인합니다. (연결 3초, 전체 5초 제한) 실패하면 종료합니다.
check_api() {
    local name="$1"
    local url="$2"

    if ! curl -fsS \
        --connect-timeout 3 \
        --max-time 5 \
        -o /dev/null \
        "$url"; then
        echo "[FAIL] $name API port-forward check failed"
        exit 1
    fi
}

# 세 API가 응답하는지 확인합니다.
check_api "Keystone" "http://127.0.0.1:15000/v3"
check_api "Nova" "http://127.0.0.1:18774/"
check_api "Placement" "http://127.0.0.1:18778/"

echo "[PASS] OpenStack API port-forwards ready"

# OS_* 환경변수 : openstack 명령이 접속할 주소와 계정 정보. 계정 정보는 Kubernetes Secret 에서 읽어 오므로 코드 안에 비밀번호가 없습니다.
export OS_AUTH_URL="http://127.0.0.1:15000/v3"
export OS_USERNAME="$(get_os_secret OS_USERNAME)"
export OS_PASSWORD="$(get_os_secret OS_PASSWORD)"
export OS_PROJECT_NAME="$(get_os_secret OS_PROJECT_NAME)"
export OS_PROJECT_DOMAIN_NAME="$(get_os_secret OS_PROJECT_DOMAIN_NAME)"
export OS_USER_DOMAIN_NAME="$(get_os_secret OS_USER_DOMAIN_NAME)"
export OS_REGION_NAME="$(get_os_secret OS_REGION_NAME)"
export OS_INTERFACE="$(get_os_secret OS_INTERFACE)"

# openstack token issue : 로그인해서 인증 토큰을 발급받습니다. 이후 API 요청에 "X-Auth-Token" 헤더로 사용합니다.
TOKEN="$(
    "$OPENSTACK_CLI" token issue \
        -f value \
        -c id
)"

if [ -z "$TOKEN" ]; then
    echo "[FAIL] OpenStack authentication failed"
    exit 1
fi

echo "[PASS] OpenStack authentication succeeded"

# Keystone service catalog
# 서비스 목록(이름, 종류)을 저장합니다. 아래 python3 -c '...' 안쪽은 작은따옴표 문자열이라 주석을 넣지 않았고, 종류 순으로 정렬합니다.
curl -fsS \
    -H "X-Auth-Token: $TOKEN" \
    http://127.0.0.1:15000/v3/services \
    | python3 -c '
import json
import sys

data = json.load(sys.stdin)

for service in sorted(
    data["services"],
    key=lambda x: (x["type"], x.get("name") or "")
):
    print(
        service.get("name", ""),
        service["type"],
        sep="\t"
    )
' > "$OUTPUT_DIR/openstack-services.txt"

# Keystone endpoints
# 엔드포인트(각 서비스 API 주소) 목록을 저장합니다. 종류(interface)와 주소 순으로 정렬합니다.
curl -fsS \
    -H "X-Auth-Token: $TOKEN" \
    http://127.0.0.1:15000/v3/endpoints \
    | python3 -c '
import json
import sys

data = json.load(sys.stdin)

for endpoint in sorted(
    data["endpoints"],
    key=lambda x: (x["interface"], x["url"])
):
    print(
        endpoint["interface"],
        endpoint["url"],
        sep="\t"
    )
' > "$OUTPUT_DIR/openstack-endpoints.txt"

# Nova compute services
# nova-compute 서비스 목록(호스트, 상태)을 저장합니다.
curl -fsS \
    -H "X-Auth-Token: $TOKEN" \
    -H "OpenStack-API-Version: compute 2.53" \
    http://127.0.0.1:18774/v2.1/os-services \
    | python3 -c '
import json
import sys

data = json.load(sys.stdin)

for service in sorted(
    data.get("services", []),
    key=lambda x: (x.get("binary", ""), x.get("host", ""))
):
    if service.get("binary") == "nova-compute":
        print(
            service.get("host", ""),
            service.get("binary", ""),
            service.get("state", ""),
            service.get("status", ""),
            sep="\t"
        )
' > "$OUTPUT_DIR/nova-compute-services.txt"

# Placement resource providers
# Placement 자원 제공자 이름 목록을 저장합니다.
curl -fsS \
    -H "X-Auth-Token: $TOKEN" \
    -H "OpenStack-API-Version: placement 1.0" \
    http://127.0.0.1:18778/resource_providers \
    | python3 -c '
import json
import sys

data = json.load(sys.stdin)

providers = sorted(
    data.get("resource_providers", []),
    key=lambda x: x.get("name", "")
)

for provider in providers:
    print(provider.get("name", ""))
' > "$OUTPUT_DIR/placement-resource-providers.txt"

# 자원 제공자 파일의 줄 수를 세어 개수를 따로 저장합니다.
RESOURCE_PROVIDER_COUNT="$(
    wc -l < "$OUTPUT_DIR/placement-resource-providers.txt"
)"

printf '%s\n' "$RESOURCE_PROVIDER_COUNT" \
    > "$OUTPUT_DIR/placement-resource-provider-count.txt"

# 작업이 끝났으므로 토큰과 계정 정보 환경변수를 지워서, 이후에 남지 않게 합니다.
unset TOKEN
unset OS_AUTH_URL
unset OS_USERNAME
unset OS_PASSWORD
unset OS_PROJECT_NAME
unset OS_PROJECT_DOMAIN_NAME
unset OS_USER_DOMAIN_NAME
unset OS_REGION_NAME
unset OS_INTERFACE

echo "[PASS] OpenStack state collected"
echo "[PASS] Final state collection completed"
