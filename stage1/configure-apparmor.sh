#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_ROOT}/common/common.sh"

APPARMOR_RULE="/var/lib/libvirt/images/** rwk,"
APPARMOR_FILE="/etc/apparmor.d/local/abstractions/libvirt-qemu"

print_header "OpenInfra Lab Kit - Stage 1 AppArmor Configuration"

# ----------------------------------------
# 1. Check AppArmor
# ----------------------------------------

if ! command -v aa-status >/dev/null 2>&1; then
    print_info "AppArmor is not installed. Skipping configuration."
    exit 0
fi

print_pass "AppArmor available"

# ----------------------------------------
# 2. Prepare local rule file
# ----------------------------------------

if [ ! -f "${APPARMOR_FILE}" ]; then
    print_info "Creating AppArmor local rule file"

    sudo mkdir -p "$(dirname "${APPARMOR_FILE}")" || {
        print_error_detail \
            "Stage 1" \
            "AppArmor configuration" \
            "Failed to create AppArmor local configuration directory" \
            "N/A"
        exit 1
    }

    sudo touch "${APPARMOR_FILE}" || {
        print_error_detail \
            "Stage 1" \
            "AppArmor configuration" \
            "Failed to create ${APPARMOR_FILE}" \
            "N/A"
        exit 1
    }
fi

# ----------------------------------------
# 3. Add libvirt image access rule
# ----------------------------------------

if sudo grep -Fqx "${APPARMOR_RULE}" "${APPARMOR_FILE}"; then
    print_pass "AppArmor libvirt image rule already exists"
else
    print_info "Adding AppArmor rule for libvirt images"

    echo "${APPARMOR_RULE}" | sudo tee -a "${APPARMOR_FILE}" >/dev/null || {
        print_error_detail \
            "Stage 1" \
            "AppArmor configuration" \
            "Failed to add libvirt image access rule" \
            "N/A"
        exit 1
    }

    print_pass "AppArmor libvirt image rule added"
fi

# ----------------------------------------
# 4. Reload AppArmor
# ----------------------------------------

print_info "Reloading AppArmor configuration"

if command -v apparmor_parser >/dev/null 2>&1 && \
   [ -f /etc/apparmor.d/usr.sbin.libvirtd ]; then

    sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.libvirtd || {
        print_error_detail \
            "Stage 1" \
            "AppArmor reload" \
            "Failed to reload libvirt AppArmor profile" \
            "N/A"
        exit 1
    }

else
    sudo systemctl reload apparmor || {
        print_error_detail \
            "Stage 1" \
            "AppArmor reload" \
            "Failed to reload AppArmor service" \
            "N/A"
        exit 1
    }
fi

print_pass "AppArmor configuration reloaded"

echo
echo "========================================"
echo " Stage 1 AppArmor configuration completed"
echo "========================================"