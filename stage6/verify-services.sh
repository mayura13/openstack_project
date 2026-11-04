#!/usr/bin/env bash
# ==============================================================
# stage6/verify-services.sh - [6단계] OpenStack 서비스 동작 검증
# ==============================================================
# OpenStack이 설치된 뒤 "서비스가 실제로 동작하는지"를 API로 직접 확인합니다. (결과는 [PASS]/[FAIL])
#   Keystone : API 응답 확인, 인증 토큰 발급
#   Glance   : 작은 테스트 이미지 등록(업로드)과 삭제, 상태가 active 인지 확인
#   Neutron  : 테스트 네트워크 생성/조회/삭제, 네트워크 에이전트가 모두 정상(alive)인지
#   Nova     : nova-compute 서비스 2개와 하이퍼바이저 2개가 up/enabled 인지
#   Placement: 자원 제공자(resource provider) 2개 확인
# 실행: bash stage6/verify-services.sh [결과 저장 폴더]   (생략하면 logs/verify)
#       Makefile에는 연결되어 있지 않으므로 직접 실행합니다. (stage5 postcheck 통과 후 실행)
# 실패하면: [FAIL] 메시지가 어느 서비스의 어느 항목인지 알려 줍니다. 즉시 종료하며, 종료 전에 테스트 리소스를 자동 정리합니다.
#
# 동작 방식
#   OpenStack API는 Kubernetes 클러스터 안에 있으므로 `kubectl port-forward` 로 내 서버의 127.0.0.1 포트에 연결하고,
#   거기에 curl 로 API 요청을 보냅니다. 관리자 계정 정보는 Kubernetes Secret 에서 읽어 오므로 이 코드 안에는 비밀번호가 없습니다.
#
# set -euo pipefail : 명령이 하나라도 실패하면 즉시 멈춥니다. (-e 실패 시 중단 / -u 없는 변수 사용 시 중단 / pipefail 파이프 중간 실패도 실패)
set -euo pipefail

# PROJECT_ROOT : 프로젝트 맨 위 폴더 / OPENSTACK_CLI : 0단계에서 만든 가상환경의 openstack 명령
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENSTACK_CLI="${HOME}/venv-openstack/bin/openstack"

# VERIFY_DIR : 검증 결과 파일(port-forward 로그, 에이전트 목록 등)을 저장할 폴더. 첫 번째 인자가 없으면 logs/verify 입니다.
VERIFY_DIR="${1:-${PROJECT_ROOT}/logs/verify}"
mkdir -p "$VERIFY_DIR"

# PF_PIDS : 백그라운드로 띄운 port-forward 프로세스 번호(PID) 목록 (끝날 때 종료하려고 모아 둠)
# TOKEN / TEST_IMAGE_ID / TEST_NETWORK_ID : 인증 토큰과, 검증 중 만든 테스트 리소스의 ID.
# 아래 cleanup 이 이 값들을 보고 남은 테스트 리소스를 지웁니다.
PF_PIDS=()
TOKEN=""
TEST_IMAGE_ID=""
TEST_NETWORK_ID=""

# cleanup : 정리 함수. 아래 trap 때문에 스크립트가 성공/실패/중단 어떤 방식으로 끝나든 마지막에 실행됩니다.
#   1) 삭제하지 못한 테스트 이미지/네트워크가 남아 있으면 삭제
#   2) 켜 둔 port-forward 프로세스 종료
cleanup() {
    echo "[INFO] Cleaning up verification resources..."

    if [ -n "${TEST_IMAGE_ID:-}" ] && [ -n "${TOKEN:-}" ]; then
        curl -fsS -X DELETE \
            -H "X-Auth-Token: $TOKEN" \
            "http://127.0.0.1:19292/v2/images/${TEST_IMAGE_ID}" \
            >/dev/null 2>&1 || true
    fi

    if [ -n "${TEST_NETWORK_ID:-}" ] && [ -n "${TOKEN:-}" ]; then
        curl -fsS -X DELETE \
            -H "X-Auth-Token: $TOKEN" \
            "http://127.0.0.1:19696/v2.0/networks/${TEST_NETWORK_ID}" \
            >/dev/null 2>&1 || true
    fi

    for pid in "${PF_PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
}

# trap cleanup EXIT : 스크립트가 끝날 때(성공이든 실패든) cleanup 함수를 실행하도록 등록합니다.
trap cleanup EXIT

# fail "메시지" : [FAIL] 메시지를 출력하고 즉시 종료(exit 1)합니다. 종료 때 cleanup 이 실행됩니다.
fail() {
    echo "[FAIL] $1"
    exit 1
}

# get_os_secret <키 이름> : Kubernetes Secret(keystone-keystone-admin)에서 관리자 계정 정보 한 항목을 읽어 옵니다.
# Secret의 값은 base64 로 인코딩되어 저장되므로 base64 -d 로 원래 글자로 되돌립니다.
get_os_secret() {
    kubectl get secret keystone-keystone-admin \
        -n openstack \
        -o "jsonpath={.data.$1}" | base64 -d
}

# check_api <이름> <주소> : 그 주소에 접속이 되는지 확인합니다. (연결 3초, 전체 5초 제한) 실패하면 [FAIL]로 종료합니다.
check_api() {
    local name="$1"
    local url="$2"

    curl -fsS \
        --connect-timeout 3 \
        --max-time 5 \
        -o /dev/null \
        "$url" \
        || fail "$name API check failed"

    echo "[PASS] $name API reachable"
}

echo "========================================"
echo " OpenInfra Lab Kit Service Verification"
echo "========================================"

# openstack 명령이 있는지 확인하고, 없으면 중단합니다. (0단계 설치 결과)
[ -x "$OPENSTACK_CLI" ] \
    || fail "OpenStack CLI not found: $OPENSTACK_CLI"

echo
echo "===== Starting API port-forwards ====="

# kubectl port-forward svc/<서비스> <내 포트>:<서비스 포트> : 클러스터 안의 서비스를 내 서버의 127.0.0.1:<내 포트>로 연결합니다.
#   keystone-api 5000 -> 15000 / glance-api 9292 -> 19292 / neutron-server 9696 -> 19696
#   (내 포트는 다른 프로그램과 겹치지 않게 큰 번호를 썼습니다)
# 끝의 & 는 백그라운드 실행입니다. "$!" 는 방금 띄운 프로세스의 번호(PID)이고, 나중에 종료할 수 있게 PF_PIDS 에 저장합니다.
# >파일 2>&1 : 출력과 오류를 VERIFY_DIR 의 로그 파일에 저장합니다.
kubectl port-forward -n openstack \
    svc/keystone-api 15000:5000 \
    >"$VERIFY_DIR/port-forward-keystone.log" 2>&1 &
PF_PIDS+=("$!")

kubectl port-forward -n openstack \
    svc/glance-api 19292:9292 \
    >"$VERIFY_DIR/port-forward-glance.log" 2>&1 &
PF_PIDS+=("$!")

kubectl port-forward -n openstack \
    svc/neutron-server 19696:9696 \
    >"$VERIFY_DIR/port-forward-neutron.log" 2>&1 &
PF_PIDS+=("$!")

# port-forward 연결이 준비될 때까지 3초 기다립니다.
sleep 3

# 세 서비스(Keystone, Glance, Neutron) API가 응답하는지 확인합니다.
check_api "Keystone" "http://127.0.0.1:15000/v3"
check_api "Glance" "http://127.0.0.1:19292/"
check_api "Neutron" "http://127.0.0.1:19696/"

echo
echo "===== Keystone Verification ====="

# OS_* 환경변수 : openstack 명령이 "어디에 어떤 계정으로 접속할지" 읽는 값입니다.
# OS_AUTH_URL 은 Keystone 주소이고, 나머지(계정, 비밀번호, 프로젝트 등)는 Kubernetes Secret 에서 읽어 옵니다.
export OS_AUTH_URL="http://127.0.0.1:15000/v3"
export OS_USERNAME="$(get_os_secret OS_USERNAME)"
export OS_PASSWORD="$(get_os_secret OS_PASSWORD)"
export OS_PROJECT_NAME="$(get_os_secret OS_PROJECT_NAME)"
export OS_PROJECT_DOMAIN_NAME="$(get_os_secret OS_PROJECT_DOMAIN_NAME)"
export OS_USER_DOMAIN_NAME="$(get_os_secret OS_USER_DOMAIN_NAME)"
export OS_REGION_NAME="$(get_os_secret OS_REGION_NAME)"
export OS_INTERFACE="$(get_os_secret OS_INTERFACE)"

# openstack token issue : Keystone에 로그인해서 인증 토큰을 발급받습니다. (-f value -c id : 토큰 문자열(id)만 출력)
# 이후 API 요청에는 이 토큰을 "X-Auth-Token" 헤더에 담아 보냅니다. 발급이 실패하거나 비어 있으면 [FAIL] 입니다.
TOKEN="$(
    "$OPENSTACK_CLI" token issue \
        -f value \
        -c id
)" || fail "Keystone token issue failed"

[ -n "$TOKEN" ] || fail "Keystone returned empty token"

echo "[PASS] Keystone token issued"

# --------------------------------------------------
# Glance
# --------------------------------------------------

echo
echo "===== Glance Verification ====="

# [Glance 검증] 4단계: (1) 이미지 정보 등록 -> (2) 데이터 업로드 -> (3) 상태가 active 인지 확인 -> (4) 삭제
# 테스트 이미지는 한 줄짜리 작은 텍스트 파일(실제 OS 이미지가 아님)입니다. 서비스 동작 확인이 목적이라서 이것으로 충분합니다.
TEST_IMAGE_FILE="$(mktemp)"
printf '%s\n' \
    "OpenInfra Lab Kit Glance verification" \
    > "$TEST_IMAGE_FILE"

# (1) POST /v2/images : 이미지의 "정보"(이름, 형식)만 먼저 등록합니다. 성공하면 이미지 ID가 응답에 들어 있습니다.
# curl 옵션: -f(HTTP 오류면 실패) -s(진행 표시 숨김) -S(오류는 표시) -X POST(요청 방식) -H(헤더) -d(보낼 데이터)
IMAGE_RESPONSE="$(
    curl -fsS -X POST \
        -H "X-Auth-Token: $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{
              "name": "openinfra-verify-image",
              "disk_format": "raw",
              "container_format": "bare"
            }' \
        http://127.0.0.1:19292/v2/images
)" || fail "Glance test image creation failed"

# 응답(JSON)에서 이미지 ID를 python3 로 꺼냅니다.
TEST_IMAGE_ID="$(
    printf '%s' "$IMAGE_RESPONSE" |
        python3 -c \
        'import json,sys; print(json.load(sys.stdin)["id"])'
)"

[ -n "$TEST_IMAGE_ID" ] \
    || fail "Glance returned empty image ID"

# (2) PUT /v2/images/<ID>/file : 이미지 데이터(위의 작은 파일)를 업로드합니다.
curl -fsS -X PUT \
    -H "X-Auth-Token: $TOKEN" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$TEST_IMAGE_FILE" \
    "http://127.0.0.1:19292/v2/images/${TEST_IMAGE_ID}/file" \
    >/dev/null \
    || fail "Glance test image upload failed"

# (3) GET /v2/images/<ID> : 이미지 정보를 다시 조회해서 status 를 읽습니다. 업로드가 끝나면 "active" 여야 합니다.
IMAGE_STATUS="$(
    curl -fsS \
        -H "X-Auth-Token: $TOKEN" \
        "http://127.0.0.1:19292/v2/images/${TEST_IMAGE_ID}" |
        python3 -c \
        'import json,sys; print(json.load(sys.stdin)["status"])'
)"

rm -f "$TEST_IMAGE_FILE"

[ "$IMAGE_STATUS" = "active" ] \
    || fail "Glance image status is '$IMAGE_STATUS', expected 'active'"

echo "[PASS] Glance image create/upload: status=active"

# (4) DELETE : 테스트 이미지를 삭제합니다. 삭제에 성공하면 TEST_IMAGE_ID 를 비워서 cleanup 이 다시 지우려 하지 않게 합니다.
curl -fsS -X DELETE \
    -H "X-Auth-Token: $TOKEN" \
    "http://127.0.0.1:19292/v2/images/${TEST_IMAGE_ID}" \
    >/dev/null \
    || fail "Glance test image deletion failed"

TEST_IMAGE_ID=""

echo "[PASS] Glance test image deleted"

# --------------------------------------------------
# Neutron network CRUD
# --------------------------------------------------

echo
echo "===== Neutron Network Verification ====="

# [Neutron 네트워크 검증] 테스트 네트워크를 만들고(POST), 다시 읽고(GET), 지웁니다(DELETE).
# POST /v2.0/networks : "openinfra-verify-network" 이름의 네트워크 생성
NETWORK_RESPONSE="$(
    curl -fsS -X POST \
        -H "X-Auth-Token: $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{
              "network": {
                "name": "openinfra-verify-network",
                "admin_state_up": true
              }
            }' \
        http://127.0.0.1:19696/v2.0/networks
)" || fail "Neutron test network creation failed"

# 응답(JSON)에서 네트워크 ID를 꺼냅니다.
TEST_NETWORK_ID="$(
    printf '%s' "$NETWORK_RESPONSE" |
        python3 -c \
        'import json,sys; print(json.load(sys.stdin)["network"]["id"])'
)"

[ -n "$TEST_NETWORK_ID" ] \
    || fail "Neutron returned empty network ID"

# GET : 만든 네트워크를 다시 조회해서 상태(status)를 읽어 출력합니다.
NETWORK_STATUS="$(
    curl -fsS \
        -H "X-Auth-Token: $TOKEN" \
        "http://127.0.0.1:19696/v2.0/networks/${TEST_NETWORK_ID}" |
        python3 -c \
        'import json,sys; print(json.load(sys.stdin)["network"]["status"])'
)"

echo "[PASS] Neutron network create/read: status=${NETWORK_STATUS}"

# DELETE : 테스트 네트워크 삭제. 삭제에 성공하면 TEST_NETWORK_ID 를 비워서 cleanup 이 다시 지우려 하지 않게 합니다.
curl -fsS -X DELETE \
    -H "X-Auth-Token: $TOKEN" \
    "http://127.0.0.1:19696/v2.0/networks/${TEST_NETWORK_ID}" \
    >/dev/null \
    || fail "Neutron test network deletion failed"

TEST_NETWORK_ID=""

echo "[PASS] Neutron test network deleted"

# --------------------------------------------------
# Neutron agents
# --------------------------------------------------

echo
echo "===== Neutron Agent Verification ====="

# [Neutron 에이전트 검증] GET /v2.0/agents 로 에이전트 목록을 받아서 python3 로 검사합니다.
# 에이전트(agent) = 각 노드에서 네트워크 작업을 하는 프로그램 (예: DHCP, L3, Open vSwitch)
# 모든 에이전트가 alive=True 이고 admin_state_up=True 여야 통과이고, 하나도 없어도 실패입니다.
# (아래 python3 -c '...' 안쪽은 작은따옴표 문자열이라 주석을 넣을 수 없어서 설명을 이곳에 적었습니다)
AGENT_RESULT="$(
    curl -fsS \
        -H "X-Auth-Token: $TOKEN" \
        "http://127.0.0.1:19696/v2.0/agents" |
        python3 -c '
import json
import sys

data = json.load(sys.stdin)
agents = data.get("agents", [])

if not agents:
    print("No Neutron agents found", file=sys.stderr)
    sys.exit(1)

failed = []

for agent in sorted(
    agents,
    key=lambda x: (x.get("agent_type", ""), x.get("host", ""))
):
    agent_type = agent.get("agent_type", "")
    host = agent.get("host", "")
    alive = agent.get("alive", False)
    admin_up = agent.get("admin_state_up", False)

    print(
        f"{agent_type}\t{host}\t"
        f"alive={alive}\tadmin_state_up={admin_up}"
    )

    if not alive or not admin_up:
        failed.append((agent_type, host))

if failed:
    sys.exit(1)
'
)" || fail "One or more Neutron agents are unhealthy"

# 에이전트 상태 목록을 결과 파일(neutron-agents.txt)로 저장합니다.
printf '%s\n' "$AGENT_RESULT" \
    > "$VERIFY_DIR/neutron-agents.txt"

AGENT_COUNT="$(printf '%s\n' "$AGENT_RESULT" | grep -c .)"

echo "[PASS] All ${AGENT_COUNT} Neutron agents healthy"

# --------------------------------------------------
# Nova
# --------------------------------------------------

echo
echo "===== Nova Verification ====="

# [Nova 검증] Nova API(8774 -> 로컬 18774)에도 port-forward 를 연결합니다.
kubectl port-forward -n openstack \
    svc/nova-api 18774:8774 \
    >"$VERIFY_DIR/port-forward-nova.log" 2>&1 &
PF_PIDS+=("$!")

sleep 2

check_api "Nova" "http://127.0.0.1:18774/"

# GET /v2.1/os-services : Nova 서비스 목록에서 nova-compute 만 골라, 정확히 2개이고 모두 state=up, status=enabled 인지 확인합니다.
# "OpenStack-API-Version: compute 2.53" 헤더는 사용할 API 버전(microversion)을 지정합니다.
NOVA_RESULT="$(
    curl -fsS \
        -H "X-Auth-Token: $TOKEN" \
        -H "OpenStack-API-Version: compute 2.53" \
        http://127.0.0.1:18774/v2.1/os-services |
        python3 -c '
import json
import sys

services = [
    s for s in json.load(sys.stdin).get("services", [])
    if s.get("binary") == "nova-compute"
]

for s in sorted(services, key=lambda x: x.get("host", "")):
    print(
        s.get("host", ""),
        s.get("state", ""),
        s.get("status", ""),
        sep="\t"
    )

if len(services) != 2:
    sys.exit(1)

if any(
    s.get("state") != "up" or s.get("status") != "enabled"
    for s in services
):
    sys.exit(1)
'
)" || fail "Nova compute service verification failed"

printf '%s\n' "$NOVA_RESULT" \
    > "$VERIFY_DIR/nova-compute-services.txt"

echo "[PASS] Nova compute services: 2 up/enabled"

# GET /v2.1/os-hypervisors/detail : 하이퍼바이저(VM을 실제로 실행하는 컴퓨트 노드) 목록.
# 정확히 2개이고 모두 state=up, status=enabled 여야 통과입니다.
HYPERVISOR_RESULT="$(
    curl -fsS \
        -H "X-Auth-Token: $TOKEN" \
        -H "OpenStack-API-Version: compute 2.53" \
        http://127.0.0.1:18774/v2.1/os-hypervisors/detail |
        python3 -c '
import json
import sys

hypervisors = json.load(sys.stdin).get("hypervisors", [])

for h in sorted(
    hypervisors,
    key=lambda x: x.get("hypervisor_hostname", "")
):
    print(
        h.get("hypervisor_hostname", ""),
        h.get("state", ""),
        h.get("status", ""),
        sep="\t"
    )

if len(hypervisors) != 2:
    sys.exit(1)

if any(
    h.get("state") != "up" or h.get("status") != "enabled"
    for h in hypervisors
):
    sys.exit(1)
'
)" || fail "Nova hypervisor verification failed"

printf '%s\n' "$HYPERVISOR_RESULT" \
    > "$VERIFY_DIR/nova-hypervisors.txt"

echo "[PASS] Nova hypervisors: 2 up/enabled"

# --------------------------------------------------
# Placement
# --------------------------------------------------

echo
echo "===== Placement Verification ====="

# [Placement 검증] Placement API(8778 -> 로컬 18778)에 port-forward 를 연결합니다.
kubectl port-forward -n openstack \
    svc/placement-api 18778:8778 \
    >"$VERIFY_DIR/port-forward-placement.log" 2>&1 &
PF_PIDS+=("$!")

sleep 2

check_api "Placement" "http://127.0.0.1:18778/"

# GET /resource_providers : 자원 제공자 목록. 컴퓨트 노드 2대가 각각 제공자로 등록되어 정확히 2개여야 통과입니다.
# Nova와 Placement가 서로 연동되어 컴퓨트 노드를 등록했다는 뜻이기도 합니다.
PLACEMENT_RESULT="$(
    curl -fsS \
        -H "X-Auth-Token: $TOKEN" \
        -H "OpenStack-API-Version: placement 1.0" \
        http://127.0.0.1:18778/resource_providers |
        python3 -c '
import json
import sys

providers = json.load(sys.stdin).get("resource_providers", [])

for p in sorted(providers, key=lambda x: x.get("name", "")):
    print(p.get("name", ""))

if len(providers) != 2:
    sys.exit(1)
'
)" || fail "Placement resource provider verification failed"

printf '%s\n' "$PLACEMENT_RESULT" \
    > "$VERIFY_DIR/placement-resource-providers.txt"

echo "[PASS] Placement resource providers: 2"

echo
echo "========================================"
echo "[PASS] Service verification completed"
echo "========================================"
