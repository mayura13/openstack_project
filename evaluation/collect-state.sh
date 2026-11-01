#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <output-directory>"
    echo "Example: $0 logs/baseline/final-state"
    exit 1
fi

OUTPUT_DIR="$1"

if [[ "$OUTPUT_DIR" != /* ]]; then
    OUTPUT_DIR="${PROJECT_ROOT}/${OUTPUT_DIR}"
fi

mkdir -p "$OUTPUT_DIR"

echo "[INFO] Collecting final deployment state..."

# --------------------------------------------------
# 1. Kubernetes nodes
# --------------------------------------------------

kubectl get nodes \
    -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,VERSION:.status.nodeInfo.kubeletVersion' \
    --no-headers \
    | sort > "$OUTPUT_DIR/kubernetes-nodes.txt"

# --------------------------------------------------
# 2. Pod state summary by namespace and phase
# --------------------------------------------------

kubectl get pods -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.status.phase}{"\n"}{end}' \
    | sort \
    | uniq -c \
    | awk '{print $2 "\t" $3 "\t" $1}' \
    | sort > "$OUTPUT_DIR/pod-summary.txt"

# --------------------------------------------------
# 3. Helm releases
# --------------------------------------------------

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

OPENSTACK_CLI="${HOME}/venv-openstack/bin/openstack"

if [ ! -x "$OPENSTACK_CLI" ]; then
    echo "[FAIL] OpenStack CLI not found: $OPENSTACK_CLI"
    exit 1
fi

get_os_secret() {
    kubectl get secret keystone-keystone-admin \
        -n openstack \
        -o "jsonpath={.data.$1}" | base64 -d
}

PF_PIDS=()

cleanup_port_forwards() {
    for pid in "${PF_PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
}

trap cleanup_port_forwards EXIT

echo "[INFO] Starting OpenStack API port-forwards..."

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

sleep 3

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

check_api "Keystone" "http://127.0.0.1:15000/v3"
check_api "Nova" "http://127.0.0.1:18774/"
check_api "Placement" "http://127.0.0.1:18778/"

echo "[PASS] OpenStack API port-forwards ready"

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
)"

if [ -z "$TOKEN" ]; then
    echo "[FAIL] OpenStack authentication failed"
    exit 1
fi

echo "[PASS] OpenStack authentication succeeded"

# Keystone service catalog
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

RESOURCE_PROVIDER_COUNT="$(
    wc -l < "$OUTPUT_DIR/placement-resource-providers.txt"
)"

printf '%s\n' "$RESOURCE_PROVIDER_COUNT" \
    > "$OUTPUT_DIR/placement-resource-provider-count.txt"

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
