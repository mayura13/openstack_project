#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENSTACK_CLI="${HOME}/venv-openstack/bin/openstack"

VERIFY_DIR="${1:-${PROJECT_ROOT}/logs/verify}"
mkdir -p "$VERIFY_DIR"

PF_PIDS=()
TOKEN=""
TEST_IMAGE_ID=""
TEST_NETWORK_ID=""

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

trap cleanup EXIT

fail() {
    echo "[FAIL] $1"
    exit 1
}

get_os_secret() {
    kubectl get secret keystone-keystone-admin \
        -n openstack \
        -o "jsonpath={.data.$1}" | base64 -d
}

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

[ -x "$OPENSTACK_CLI" ] \
    || fail "OpenStack CLI not found: $OPENSTACK_CLI"

echo
echo "===== Starting API port-forwards ====="

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

sleep 3

check_api "Keystone" "http://127.0.0.1:15000/v3"
check_api "Glance" "http://127.0.0.1:19292/"
check_api "Neutron" "http://127.0.0.1:19696/"

echo
echo "===== Keystone Verification ====="

export OS_AUTH_URL="http://127.0.0.1:15000/v3"
export OS_USERNAME="$(get_os_secret OS_USERNAME)"
export OS_PASSWORD="$(get_os_secret OS_PASSWORD)"
export OS_PROJECT_NAME="$(get_os_secret OS_PROJECT_NAME)"
export OS_PROJECT_DOMAIN_NAME="$(get_os_secret OS_PROJECT_DOMAIN_NAME)"
export OS_USER_DOMAIN_NAME="$(get_os_secret OS_USER_DOMAIN_NAME)"
export OS_REGION_NAME="$(get_os_secret OS_REGION_NAME)"
export OS_INTERFACE="$(get_os_secret OS_INTERFACE)"

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

TEST_IMAGE_FILE="$(mktemp)"
printf '%s\n' \
    "OpenInfra Lab Kit Glance verification" \
    > "$TEST_IMAGE_FILE"

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

TEST_IMAGE_ID="$(
    printf '%s' "$IMAGE_RESPONSE" |
        python3 -c \
        'import json,sys; print(json.load(sys.stdin)["id"])'
)"

[ -n "$TEST_IMAGE_ID" ] \
    || fail "Glance returned empty image ID"

curl -fsS -X PUT \
    -H "X-Auth-Token: $TOKEN" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$TEST_IMAGE_FILE" \
    "http://127.0.0.1:19292/v2/images/${TEST_IMAGE_ID}/file" \
    >/dev/null \
    || fail "Glance test image upload failed"

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

TEST_NETWORK_ID="$(
    printf '%s' "$NETWORK_RESPONSE" |
        python3 -c \
        'import json,sys; print(json.load(sys.stdin)["network"]["id"])'
)"

[ -n "$TEST_NETWORK_ID" ] \
    || fail "Neutron returned empty network ID"

NETWORK_STATUS="$(
    curl -fsS \
        -H "X-Auth-Token: $TOKEN" \
        "http://127.0.0.1:19696/v2.0/networks/${TEST_NETWORK_ID}" |
        python3 -c \
        'import json,sys; print(json.load(sys.stdin)["network"]["status"])'
)"

echo "[PASS] Neutron network create/read: status=${NETWORK_STATUS}"

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

printf '%s\n' "$AGENT_RESULT" \
    > "$VERIFY_DIR/neutron-agents.txt"

AGENT_COUNT="$(printf '%s\n' "$AGENT_RESULT" | grep -c .)"

echo "[PASS] All ${AGENT_COUNT} Neutron agents healthy"

# --------------------------------------------------
# Nova
# --------------------------------------------------

echo
echo "===== Nova Verification ====="

kubectl port-forward -n openstack \
    svc/nova-api 18774:8774 \
    >"$VERIFY_DIR/port-forward-nova.log" 2>&1 &
PF_PIDS+=("$!")

sleep 2

check_api "Nova" "http://127.0.0.1:18774/"

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

kubectl port-forward -n openstack \
    svc/placement-api 18778:8778 \
    >"$VERIFY_DIR/port-forward-placement.log" 2>&1 &
PF_PIDS+=("$!")

sleep 2

check_api "Placement" "http://127.0.0.1:18778/"

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
