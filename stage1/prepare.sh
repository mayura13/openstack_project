#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_ROOT}/common/common.sh"

IMAGE_DIR="${HOME}/images"
IMAGE_NAME="noble-server-cloudimg-amd64.img"

IMAGE_RELEASE="20261017"
IMAGE_URL="https://cloud-images.ubuntu.com/noble/${IMAGE_RELEASE}/${IMAGE_NAME}"

IMAGE_SHA256="04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94"

IMAGE_PATH="${IMAGE_DIR}/${IMAGE_NAME}"

SSH_DIR="${HOME}/.ssh"
SSH_KEY="${SSH_DIR}/id_vm_ed25519"

print_header "OpenInfra Lab Kit - Stage 1 Prepare"

# ----------------------------------------
# 1. Image directory
# ----------------------------------------

if [ ! -d "${IMAGE_DIR}" ]; then
    print_info "Creating image directory: ${IMAGE_DIR}"

    mkdir -p "${IMAGE_DIR}" || {
        print_error_detail \
            "Stage 1" \
            "Image directory" \
            "Failed to create ${IMAGE_DIR}" \
            "N/A"
        exit 1
    }
fi

print_pass "Image directory ready"

# ----------------------------------------
# 2. Ubuntu cloud image
# ----------------------------------------

if [ -f "${IMAGE_PATH}" ]; then
    print_pass "Ubuntu cloud image already exists"
else
    print_info "Downloading Ubuntu 24.04 cloud image"

    curl -fL \
        "${IMAGE_URL}" \
        -o "${IMAGE_PATH}" || {
            rm -f "${IMAGE_PATH}"

            print_error_detail \
                "Stage 1" \
                "Ubuntu cloud image download" \
                "Failed to download Ubuntu 24.04 cloud image" \
                "N/A"
            exit 1
        }

    print_pass "Ubuntu cloud image downloaded"
fi

# ----------------------------------------
# 3. SHA256 verification
# ----------------------------------------

print_info "Verifying Ubuntu cloud image SHA256"

ACTUAL_SHA256="$(sha256sum "${IMAGE_PATH}" | awk '{print $1}')"

if [[ "${ACTUAL_SHA256}" != "${IMAGE_SHA256}" ]]; then
    print_error_detail \
        "Stage 1" \
        "Image checksum" \
        "Ubuntu cloud image SHA256 mismatch" \
        "Expected: ${IMAGE_SHA256}, Actual: ${ACTUAL_SHA256}"
    exit 1
fi

print_pass "Ubuntu cloud image checksum verified"

# ----------------------------------------
# 4. SSH directory
# ----------------------------------------

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"

# ----------------------------------------
# 5. SSH key
# ----------------------------------------

if [ -f "${SSH_KEY}" ] && [ -f "${SSH_KEY}.pub" ]; then
    print_pass "SSH key already exists"
else
    print_info "Creating SSH key"

    ssh-keygen \
        -t ed25519 \
        -f "${SSH_KEY}" \
        -N "" \
        -C "openinfra-lab" || {
            print_error_detail \
                "Stage 1" \
                "SSH key generation" \
                "Failed to create SSH key" \
                "N/A"
            exit 1
        }

    print_pass "SSH key created"
fi

# ----------------------------------------
# Complete
# ----------------------------------------

echo
echo "========================================"
echo " Stage 1 preparation completed"
echo "========================================"
echo

print_info "Image: ${IMAGE_PATH}"
print_info "SSH public key: ${SSH_KEY}.pub"