#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_ROOT}/common/common.sh"
source "${PROJECT_ROOT}/versions.env"

PASS=0
FAIL=0

print_header "OpenInfra Lab Kit - Stage 1 Preflight"

check_pass() {
    print_pass "$1"
    PASS=$((PASS + 1))
}

check_fail() {
    print_fail "$1"
    FAIL=$((FAIL + 1))
}

# ----------------------------------------
# 1. Terraform
# ----------------------------------------

if command -v terraform >/dev/null 2>&1 && \
   terraform version | head -1 | grep -q "v${TERRAFORM_VERSION}"; then
    check_pass "Terraform ${TERRAFORM_VERSION}"
else
    check_fail "Terraform ${TERRAFORM_VERSION}"
fi

# ----------------------------------------
# 2. libvirt
# ----------------------------------------

if virsh list --all >/dev/null 2>&1; then
    check_pass "libvirt connection"
else
    check_fail "libvirt connection"
fi

# ----------------------------------------
# 3. KVM
# ----------------------------------------

if [ -c /dev/kvm ]; then
    check_pass "/dev/kvm exists"
else
    check_fail "/dev/kvm exists"
fi

# ----------------------------------------
# 4. User permissions
# ----------------------------------------

if id -nG | grep -qw libvirt; then
    check_pass "User belongs to libvirt group"
else
    check_fail "User belongs to libvirt group"
fi

if id -nG | grep -qw kvm; then
    check_pass "User belongs to kvm group"
else
    check_fail "User belongs to kvm group"
fi

# ----------------------------------------
# 5. Storage space
# ----------------------------------------

AVAILABLE_GB=$(df --output=avail -BG /var/lib/libvirt 2>/dev/null \
    | tail -1 \
    | tr -dc '0-9')

if [ -n "${AVAILABLE_GB}" ] && [ "${AVAILABLE_GB}" -ge 340 ]; then
    check_pass "libvirt storage available: ${AVAILABLE_GB} GiB"
else
    check_fail "libvirt storage requires at least 340 GiB"
fi

# ----------------------------------------
# 6. SSH
# ----------------------------------------

if command -v ssh >/dev/null 2>&1; then
    check_pass "SSH client available"
else
    check_fail "SSH client available"
fi

# ----------------------------------------
# 7. Existing OpenInfra resources
# ----------------------------------------

EXISTING_VMS="$(
    virsh list --all --name 2>/dev/null \
        | grep -E '^(cp|ctrl-worker|compute-1|compute-2)$' || true
)"

if [ -z "${EXISTING_VMS}" ]; then
    check_pass "No conflicting OpenInfra virtual machines"
else
    check_fail "Existing OpenInfra virtual machines detected"

    print_error_detail \
        "Stage 1" \
        "Existing VM check" \
        "One or more Stage 1 VM names already exist: $(echo "${EXISTING_VMS}" | tr '\n' ' ')" \
        "N/A"
fi

# ----------------------------------------
# Result
# ----------------------------------------

echo
echo "========================================"
echo " Stage 1 Preflight Result"
echo " PASS: $PASS"
echo " FAIL: $FAIL"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    echo "[X] Stage 1 preflight FAILED"
    exit 1
fi

echo "[O] Stage 1 preflight PASSED"
exit 0