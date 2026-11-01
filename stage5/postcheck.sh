#!/usr/bin/env bash
set -uo pipefail

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

echo "========================================"
echo " Stage 5 - OpenStack-Helm Postcheck"
echo "========================================"

# 1. Expected Helm releases
EXPECTED_RELEASES=(
    rabbitmq
    mariadb
    memcached
    ingress-nginx
    keystone
    glance
    openvswitch
    libvirt
    placement
    nova
    neutron
)

RELEASE_FAIL=0

for release in "${EXPECTED_RELEASES[@]}"; do
    status="$(helm status "$release" -n openstack \
        -o json 2>/dev/null |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["status"])' \
        2>/dev/null || true)"

    if [ "$status" != "deployed" ]; then
        echo "  - ${release}: ${status:-NOT FOUND}"
        RELEASE_FAIL=1
    fi
done

if [ "$RELEASE_FAIL" -eq 0 ]; then
    pass "all 11 Helm releases deployed"
else
    fail "one or more Helm releases are not deployed"
fi

# 2. Non-completed pods must be Ready
BAD_PODS="$(
    kubectl get pods -n openstack --no-headers 2>/dev/null |
    awk '
        $3 != "Completed" {
            split($2,a,"/");
            if (a[1] != a[2]) print
        }
    '
)"

if [ -z "$BAD_PODS" ]; then
    pass "all non-Completed OpenStack pods Ready"
else
    fail "one or more OpenStack pods are not Ready"
    echo "$BAD_PODS"
fi

# 3. ingress-nginx controller
if kubectl get pods -n openstack -l app=ingress-api \
    --no-headers 2>/dev/null |
    awk '$2=="1/1" && $3=="Running"{ok=1} END{exit !ok}'
then
    pass "ingress-openstack controller Running"
else
    fail "ingress-openstack controller not Running"
fi

# 4. libvirt placement
LIBVIRT_NODES="$(
    kubectl get pods -n openstack \
        -l application=libvirt,component=libvirt \
        -o wide --no-headers 2>/dev/null |
    awk '$2=="1/1" && $3=="Running"{print $7}' |
    sort -u
)"

if echo "$LIBVIRT_NODES" | grep -qx "compute-1" &&
   echo "$LIBVIRT_NODES" | grep -qx "compute-2"; then
    pass "libvirt Running on compute-1 and compute-2"
else
    fail "libvirt placement incorrect"
fi

# 5. nova-compute placement
NOVA_NODES="$(
    kubectl get pods -n openstack \
        -l application=nova,component=compute \
        -o wide --no-headers 2>/dev/null |
    awk '$2=="1/1" && $3=="Running"{print $7}' |
    sort -u
)"

if echo "$NOVA_NODES" | grep -qx "compute-1" &&
   echo "$NOVA_NODES" | grep -qx "compute-2"; then
    pass "nova-compute Running on compute-1 and compute-2"
else
    fail "nova-compute placement incorrect"
fi

# 6. All nova-compute pods must use qemu
NOVA_COMPUTE_PODS="$(
    kubectl get pods -n openstack \
        -l application=nova,component=compute \
        -o name 2>/dev/null
)"

QEMU_FAIL=0
QEMU_COUNT=0

for pod in $NOVA_COMPUTE_PODS; do
    QEMU_COUNT=$((QEMU_COUNT + 1))

    if ! kubectl exec -n openstack "$pod" \
        -c nova-compute \
        -- grep -Eq '^[[:space:]]*virt_type[[:space:]]*=[[:space:]]*qemu[[:space:]]*$' \
        /etc/nova/nova.conf 2>/dev/null; then
        QEMU_FAIL=1
    fi
done

if [ "$QEMU_COUNT" -eq 2 ] && [ "$QEMU_FAIL" -eq 0 ]; then
    pass "both nova-compute pods use virt_type=qemu"
else
    fail "nova-compute virt_type=qemu not confirmed on both compute nodes"
fi

echo
echo "========================================"
echo " Postcheck result"
echo " PASS: ${PASS}"
echo " FAIL: ${FAIL}"
echo "========================================"

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
