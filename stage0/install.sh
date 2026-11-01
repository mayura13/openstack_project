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


TERRAFORM_NEEDS_INSTALL=false

if command -v terraform >/dev/null 2>&1; then
    if terraform version | head -1 | grep -q "v${TERRAFORM_VERSION}"; then
        print_pass "Terraform ${TERRAFORM_VERSION} already installed"
    else
        CURRENT_TERRAFORM_VERSION=$(terraform version | head -1)
        print_info "Terraform version mismatch: ${CURRENT_TERRAFORM_VERSION}"
        print_info "Installing required version ${TERRAFORM_VERSION}"
        TERRAFORM_NEEDS_INSTALL=true
    fi
else
    print_info "Terraform is not installed"
    TERRAFORM_NEEDS_INSTALL=true
fi

if [ "$TERRAFORM_NEEDS_INSTALL" = true ]; then
    print_info "Installing Terraform ${TERRAFORM_VERSION}"

    TMP_DIR="$(mktemp -d)"

    curl -fsSLo "${TMP_DIR}/terraform.zip" \
        "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" || {
            rm -rf "${TMP_DIR}"
            print_error_detail \
                "Stage 0" \
                "Terraform installation" \
                "Failed to download Terraform ${TERRAFORM_VERSION}" \
                "N/A"
            exit 1
        }

    unzip -q "${TMP_DIR}/terraform.zip" -d "${TMP_DIR}" || {
        rm -rf "${TMP_DIR}"
        print_error_detail \
            "Stage 0" \
            "Terraform installation" \
            "Failed to extract Terraform archive" \
            "N/A"
        exit 1
    }

    sudo install "${TMP_DIR}/terraform" /usr/local/bin/terraform || {
        rm -rf "${TMP_DIR}"
        print_error_detail \
            "Stage 0" \
            "Terraform installation" \
            "Failed to install Terraform to /usr/local/bin" \
            "N/A"
        exit 1
    }

    rm -rf "${TMP_DIR}"

    if terraform version | head -1 | grep -q "v${TERRAFORM_VERSION}"; then
        print_pass "Terraform ${TERRAFORM_VERSION} installed"
    else
        print_error_detail \
            "Stage 0" \
            "Terraform version verification" \
            "Installed Terraform version does not match ${TERRAFORM_VERSION}" \
            "N/A"
        exit 1
    fi
fi

# ----------------------------------------
# 4. kubectl
# ----------------------------------------

KUBECTL_NEEDS_INSTALL=false

if command -v kubectl >/dev/null 2>&1; then
    if kubectl version --client 2>/dev/null | grep -q "${KUBECTL_VERSION}"; then
        print_pass "kubectl ${KUBECTL_VERSION} already installed"
    else
        CURRENT_KUBECTL_VERSION=$(kubectl version --client 2>/dev/null | head -1)
        print_info "kubectl version mismatch: ${CURRENT_KUBECTL_VERSION}"
        print_info "Installing required version ${KUBECTL_VERSION}"
        KUBECTL_NEEDS_INSTALL=true
    fi
else
    print_info "kubectl is not installed"
    KUBECTL_NEEDS_INSTALL=true
fi

if [ "$KUBECTL_NEEDS_INSTALL" = true ]; then
    print_info "Installing kubectl ${KUBECTL_VERSION}"

    TMP_DIR="$(mktemp -d)"

    curl -fsSLo "${TMP_DIR}/kubectl" \
        "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" || {
            rm -rf "${TMP_DIR}"
            print_error_detail \
                "Stage 0" \
                "kubectl installation" \
                "Failed to download kubectl ${KUBECTL_VERSION}" \
                "N/A"
            exit 1
        }

    sudo install -m 0755 "${TMP_DIR}/kubectl" /usr/local/bin/kubectl || {
        rm -rf "${TMP_DIR}"
        print_error_detail \
            "Stage 0" \
            "kubectl installation" \
            "Failed to install kubectl to /usr/local/bin" \
            "N/A"
        exit 1
    }

    rm -rf "${TMP_DIR}"

    if kubectl version --client 2>/dev/null | grep -q "${KUBECTL_VERSION}"; then
        print_pass "kubectl ${KUBECTL_VERSION} installed"
    else
        print_error_detail \
            "Stage 0" \
            "kubectl version verification" \
            "Installed kubectl version does not match ${KUBECTL_VERSION}" \
            "N/A"
        exit 1
    fi
fi
# ----------------------------------------
# 5. Helm
# ----------------------------------------

HELM_NEEDS_INSTALL=false

if command -v helm >/dev/null 2>&1; then
    if helm version --short 2>/dev/null | grep -q "v${HELM_VERSION}"; then
        print_pass "Helm ${HELM_VERSION} already installed"
    else
        CURRENT_HELM_VERSION=$(helm version --short 2>/dev/null)
        print_info "Helm version mismatch: ${CURRENT_HELM_VERSION}"
        print_info "Installing required version ${HELM_VERSION}"
        HELM_NEEDS_INSTALL=true
    fi
else
    print_info "Helm is not installed"
    HELM_NEEDS_INSTALL=true
fi

if [ "$HELM_NEEDS_INSTALL" = true ]; then
    print_info "Installing Helm ${HELM_VERSION}"

    TMP_DIR="$(mktemp -d)"

    curl -fsSLo "${TMP_DIR}/helm.tar.gz" \
        "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" || {
            rm -rf "${TMP_DIR}"
            print_error_detail \
                "Stage 0" \
                "Helm installation" \
                "Failed to download Helm ${HELM_VERSION}" \
                "N/A"
            exit 1
        }

    tar -xzf "${TMP_DIR}/helm.tar.gz" -C "${TMP_DIR}" || {
        rm -rf "${TMP_DIR}"
        print_error_detail \
            "Stage 0" \
            "Helm installation" \
            "Failed to extract Helm archive" \
            "N/A"
        exit 1
    }

    sudo install "${TMP_DIR}/linux-amd64/helm" /usr/local/bin/helm || {
        rm -rf "${TMP_DIR}"
        print_error_detail \
            "Stage 0" \
            "Helm installation" \
            "Failed to install Helm to /usr/local/bin" \
            "N/A"
        exit 1
    }

    rm -rf "${TMP_DIR}"

    if helm version --short 2>/dev/null | grep -q "v${HELM_VERSION}"; then
        print_pass "Helm ${HELM_VERSION} installed"
    else
        print_error_detail \
            "Stage 0" \
            "Helm version verification" \
            "Installed Helm version does not match ${HELM_VERSION}" \
            "N/A"
        exit 1
    fi
fi
# ----------------------------------------
# 6. Kubespray
# ----------------------------------------

if [ -d "${HOME}/kubespray/.git" ]; then
    CURRENT_KUBESPRAY_COMMIT="$(
        git -C "${HOME}/kubespray" rev-parse --short=7 HEAD 2>/dev/null
    )"

    if [ "${CURRENT_KUBESPRAY_COMMIT}" = "${KUBESPRAY_COMMIT}" ]; then
        print_pass "Kubespray ${KUBESPRAY_VERSION} (${KUBESPRAY_COMMIT}) already installed"
    else
        print_error_detail \
            "Stage 0" \
            "Kubespray version check" \
            "Existing Kubespray commit ${CURRENT_KUBESPRAY_COMMIT} does not match required commit ${KUBESPRAY_COMMIT}" \
            "N/A"
        exit 1
    fi
else
    print_info "Cloning Kubespray ${KUBESPRAY_VERSION}"

    git clone \
        --branch "${KUBESPRAY_VERSION}" \
        --depth 1 \
        https://github.com/kubernetes-sigs/kubespray.git \
        "${HOME}/kubespray" || {
            print_error_detail \
                "Stage 0" \
                "Kubespray installation" \
                "Failed to clone Kubespray ${KUBESPRAY_VERSION}" \
                "N/A"
            exit 1
        }

    CURRENT_KUBESPRAY_COMMIT="$(
        git -C "${HOME}/kubespray" rev-parse --short=7 HEAD 2>/dev/null
    )"

    if [ "${CURRENT_KUBESPRAY_COMMIT}" = "${KUBESPRAY_COMMIT}" ]; then
        print_pass "Kubespray ${KUBESPRAY_VERSION} (${KUBESPRAY_COMMIT}) cloned"
    else
        print_error_detail \
            "Stage 0" \
            "Kubespray version verification" \
            "Cloned commit ${CURRENT_KUBESPRAY_COMMIT} does not match required commit ${KUBESPRAY_COMMIT}" \
            "N/A"
        exit 1
    fi
fi


# ----------------------------------------
# 7. Kubespray Python environment
# ----------------------------------------

KUBESPRAY_VENV="${HOME}/venv-kubespray"
KUBESPRAY_REQUIREMENTS="${HOME}/kubespray/requirements.txt"
KUBESPRAY_PYTHON_NEEDS_INSTALL=false

if [ ! -d "${KUBESPRAY_VENV}" ]; then
    print_info "Creating Kubespray Python virtual environment"

    python3 -m venv "${KUBESPRAY_VENV}" || {
        print_error_detail \
            "Stage 0" \
            "Kubespray Python environment" \
            "Failed to create Python virtual environment" \
            "N/A"
        exit 1
    }

    KUBESPRAY_PYTHON_NEEDS_INSTALL=true

elif [ ! -x "${KUBESPRAY_VENV}/bin/ansible" ]; then
    print_info "Ansible is missing from existing Kubespray virtual environment"
    KUBESPRAY_PYTHON_NEEDS_INSTALL=true

elif "${KUBESPRAY_VENV}/bin/ansible" --version | head -1 | \
     grep -q "core ${ANSIBLE_CORE_VERSION}"; then

    print_pass "ansible-core ${ANSIBLE_CORE_VERSION} already installed"

else
    CURRENT_ANSIBLE_VERSION="$(
        "${KUBESPRAY_VENV}/bin/ansible" --version 2>/dev/null | head -1
    )"

    print_info "Ansible version mismatch: ${CURRENT_ANSIBLE_VERSION}"
    print_info "Installing Kubespray Python requirements"

    KUBESPRAY_PYTHON_NEEDS_INSTALL=true
fi

if [ "${KUBESPRAY_PYTHON_NEEDS_INSTALL}" = true ]; then
    "${KUBESPRAY_VENV}/bin/pip" install -U pip || {
        print_error_detail \
            "Stage 0" \
            "Kubespray Python environment" \
            "Failed to update pip" \
            "N/A"
        exit 1
    }

    "${KUBESPRAY_VENV}/bin/pip" install \
        -r "${KUBESPRAY_REQUIREMENTS}" || {
        print_error_detail \
            "Stage 0" \
            "Kubespray Python environment" \
            "Failed to install Kubespray Python requirements" \
            "N/A"
        exit 1
    }

    if "${KUBESPRAY_VENV}/bin/ansible" --version | head -1 | \
       grep -q "core ${ANSIBLE_CORE_VERSION}"; then

        print_pass "ansible-core ${ANSIBLE_CORE_VERSION} installed"

    else
        print_error_detail \
            "Stage 0" \
            "Ansible version verification" \
            "Installed ansible-core does not match required version ${ANSIBLE_CORE_VERSION}" \
            "N/A"
        exit 1
    fi
fi

# ----------------------------------------
# 8. OpenStack CLI environment
# ----------------------------------------

OPENSTACK_VENV="${HOME}/venv-openstack"
OPENSTACK_CLI_NEEDS_INSTALL=false

if [ ! -d "${OPENSTACK_VENV}" ]; then
    print_info "Creating OpenStack CLI virtual environment"

    python3 -m venv "${OPENSTACK_VENV}" || {
        print_error_detail \
            "Stage 0" \
            "OpenStack CLI environment" \
            "Failed to create Python virtual environment" \
            "N/A"
        exit 1
    }

    OPENSTACK_CLI_NEEDS_INSTALL=true

elif [ ! -x "${OPENSTACK_VENV}/bin/openstack" ]; then
    print_info "OpenStack CLI is missing from existing virtual environment"
    OPENSTACK_CLI_NEEDS_INSTALL=true

elif "${OPENSTACK_VENV}/bin/openstack" --version 2>/dev/null | \
     grep -q "${OPENSTACK_CLI_VERSION}"; then

    print_pass "OpenStack CLI ${OPENSTACK_CLI_VERSION} already installed"

else
    CURRENT_OPENSTACK_VERSION="$(
        "${OPENSTACK_VENV}/bin/openstack" --version 2>/dev/null
    )"

    print_info "OpenStack CLI version mismatch: ${CURRENT_OPENSTACK_VERSION}"
    print_info "Installing required version ${OPENSTACK_CLI_VERSION}"

    OPENSTACK_CLI_NEEDS_INSTALL=true
fi

if [ "${OPENSTACK_CLI_NEEDS_INSTALL}" = true ]; then
    "${OPENSTACK_VENV}/bin/pip" install -U pip || {
        print_error_detail \
            "Stage 0" \
            "OpenStack CLI installation" \
            "Failed to update pip" \
            "N/A"
        exit 1
    }

    "${OPENSTACK_VENV}/bin/pip" install \
        "python-openstackclient==${OPENSTACK_CLI_VERSION}" || {
        print_error_detail \
            "Stage 0" \
            "OpenStack CLI installation" \
            "Failed to install python-openstackclient ${OPENSTACK_CLI_VERSION}" \
            "N/A"
        exit 1
    }

    if "${OPENSTACK_VENV}/bin/openstack" --version 2>/dev/null | \
       grep -q "${OPENSTACK_CLI_VERSION}"; then

        print_pass "OpenStack CLI ${OPENSTACK_CLI_VERSION} installed"

    else
        print_error_detail \
            "Stage 0" \
            "OpenStack CLI version verification" \
            "Installed OpenStack CLI does not match required version ${OPENSTACK_CLI_VERSION}" \
            "N/A"
        exit 1
    fi
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