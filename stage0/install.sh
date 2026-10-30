#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${PROJECT_ROOT}/common/common.sh"
source "${PROJECT_ROOT}/versions.env"

print_header "OpenInfra Lab Kit - Stage 0 Install"

# ----------------------------------------
# 1. Base packages
# ----------------------------------------

print_info "Updating apt package index..."

sudo apt-get update || {
    print_error_detail \
        "Stage 0" \
        "apt-get update" \
        "Package repository or network may be unavailable" \
        "N/A"
    exit 1
}

print_info "Installing base packages..."

sudo apt-get install -y \
    qemu-kvm \
    libvirt-daemon-system \
    libvirt-clients \
    virtinst \
    bridge-utils \
    genisoimage \
    git \
    make \
    curl \
    unzip \
    jq \
    python3-venv \
    python3-pip || {
        print_error_detail \
            "Stage 0" \
            "Base package installation" \
            "APT package installation failed" \
            "N/A"
        exit 1
    }

print_pass "Base packages installed"


# ----------------------------------------
# 2. User groups
# ----------------------------------------

if id -nG "$USER" | grep -qw libvirt && \
   id -nG "$USER" | grep -qw kvm; then

    print_pass "User already belongs to libvirt and kvm groups"

else
    print_info "Adding $USER to libvirt and kvm groups"

    sudo usermod -aG libvirt,kvm "$USER" || {
        print_error_detail \
            "Stage 0" \
            "User group configuration" \
            "Failed to add user to libvirt/kvm groups" \
            "N/A"
        exit 1
    }

    print_info "Group membership changed. Re-login may be required."
fi


# ----------------------------------------
# 3. Terraform
# ----------------------------------------

if command -v terraform >/dev/null 2>&1; then

    if terraform version | head -1 | grep -q "v${TERRAFORM_VERSION}"; then
        print_pass "Terraform ${TERRAFORM_VERSION} already installed"
    else
        print_info "Terraform exists but version differs from ${TERRAFORM_VERSION}"
    fi

else
    print_info "Installing Terraform ${TERRAFORM_VERSION}"

    TMP_DIR="$(mktemp -d)"

    curl -fsSLo "${TMP_DIR}/terraform.zip" \
        "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" || exit 1

    unzip -q "${TMP_DIR}/terraform.zip" -d "${TMP_DIR}" || exit 1

    sudo install "${TMP_DIR}/terraform" /usr/local/bin/terraform || exit 1

    rm -rf "${TMP_DIR}"

    print_pass "Terraform ${TERRAFORM_VERSION} installed"
fi


# ----------------------------------------
# 4. kubectl
# ----------------------------------------

if command -v kubectl >/dev/null 2>&1; then

    if kubectl version --client 2>/dev/null | grep -q "${KUBECTL_VERSION}"; then
        print_pass "kubectl ${KUBECTL_VERSION} already installed"
    else
        print_info "kubectl exists but version differs from ${KUBECTL_VERSION}"
    fi

else
    print_info "Installing kubectl ${KUBECTL_VERSION}"

    TMP_DIR="$(mktemp -d)"

    curl -fsSLo "${TMP_DIR}/kubectl" \
        "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" || exit 1

    sudo install -m 0755 "${TMP_DIR}/kubectl" /usr/local/bin/kubectl || exit 1

    rm -rf "${TMP_DIR}"

    print_pass "kubectl ${KUBECTL_VERSION} installed"
fi


# ----------------------------------------
# 5. Helm
# ----------------------------------------

if command -v helm >/dev/null 2>&1; then

    if helm version --short 2>/dev/null | grep -q "v${HELM_VERSION}"; then
        print_pass "Helm ${HELM_VERSION} already installed"
    else
        print_info "Helm exists but version differs from ${HELM_VERSION}"
    fi

else
    print_info "Installing Helm ${HELM_VERSION}"

    TMP_DIR="$(mktemp -d)"

    curl -fsSLo "${TMP_DIR}/helm.tar.gz" \
        "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" || exit 1

    tar -xzf "${TMP_DIR}/helm.tar.gz" -C "${TMP_DIR}" || exit 1

    sudo install "${TMP_DIR}/linux-amd64/helm" /usr/local/bin/helm || exit 1

    rm -rf "${TMP_DIR}"

    print_pass "Helm ${HELM_VERSION} installed"
fi


# ----------------------------------------
# 6. Kubespray
# ----------------------------------------

if [ -d "${HOME}/kubespray/.git" ]; then
    print_pass "Kubespray repository already exists"
else
    print_info "Cloning Kubespray ${KUBESPRAY_VERSION}"

    git clone \
        --branch "${KUBESPRAY_VERSION}" \
        --depth 1 \
        https://github.com/kubernetes-sigs/kubespray.git \
        "${HOME}/kubespray" || exit 1

    print_pass "Kubespray ${KUBESPRAY_VERSION} cloned"
fi


# ----------------------------------------
# 7. Kubespray Python environment
# ----------------------------------------

if [ ! -d "${HOME}/venv-kubespray" ]; then
    print_info "Creating Kubespray Python virtual environment"

    python3 -m venv "${HOME}/venv-kubespray" || exit 1
fi

print_info "Installing Kubespray Python requirements"

"${HOME}/venv-kubespray/bin/pip" install -U pip || exit 1

"${HOME}/venv-kubespray/bin/pip" install \
    -r "${HOME}/kubespray/requirements.txt" || exit 1

print_pass "Kubespray Python environment ready"


# ----------------------------------------
# 8. OpenStack CLI environment
# ----------------------------------------

if [ ! -d "${HOME}/venv-openstack" ]; then
    print_info "Creating OpenStack CLI virtual environment"

    python3 -m venv "${HOME}/venv-openstack" || exit 1
fi

if "${HOME}/venv-openstack/bin/openstack" --version >/dev/null 2>&1; then
    print_pass "OpenStack CLI already installed"
else
    print_info "Installing OpenStack CLI"

    "${HOME}/venv-openstack/bin/pip" install -U pip || exit 1

    "${HOME}/venv-openstack/bin/pip" install \
        python-openstackclient || exit 1

    print_pass "OpenStack CLI installed"
fi


# ----------------------------------------
# Complete
# ----------------------------------------

echo
echo "========================================"
echo " Stage 0 installation completed"
echo "========================================"
echo

print_info "Run stage0/postcheck.sh to verify the installation."