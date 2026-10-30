#!/usr/bin/env bash

set -u

# 프로젝트 루트 경로
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 버전 정보 불러오기
source "${PROJECT_ROOT}/versions.env"

PASS=0
FAIL=0

echo "========================================"
echo " OpenInfra Lab Kit - Stage 0 Post Check"
echo "========================================"
echo

check() {
    local name="$1"
    local command="$2"

    if eval "$command" >/dev/null 2>&1; then
        echo "[O] $name"
        PASS=$((PASS + 1))
    else
        echo "[X] $name"
        FAIL=$((FAIL + 1))
    fi
}

# ----------------------------------------
# Tool version checks
# ----------------------------------------

check "Terraform ${TERRAFORM_VERSION}" \
    "terraform version | head -1 | grep -q 'v${TERRAFORM_VERSION}'"

check "kubectl ${KUBECTL_VERSION}" \
    "kubectl version --client | grep -q '${KUBECTL_VERSION}'"

check "Helm ${HELM_VERSION}" \
    "helm version --short | grep -q 'v${HELM_VERSION}'"

check "ansible-core ${ANSIBLE_CORE_VERSION}" \
    "~/venv-kubespray/bin/ansible --version | head -1 | grep -q '${ANSIBLE_CORE_VERSION}'"

check "OpenStack CLI ${OPENSTACK_CLI_VERSION}" \
    "~/venv-openstack/bin/openstack --version | grep -q '${OPENSTACK_CLI_VERSION}'"

check "Kubespray ${KUBESPRAY_VERSION}" \
    "[ \"\$(git -C ~/kubespray rev-parse --short=7 HEAD)\" = \"${KUBESPRAY_COMMIT}\" ]"

# ----------------------------------------
# Host checks
# ----------------------------------------

check "Current user is not root" \
    "[ \"\$(id -u)\" != 0 ]"

check "User belongs to libvirt group" \
    "id -nG | grep -qw libvirt"

check "User belongs to kvm group" \
    "id -nG | grep -qw kvm"

check "/dev/kvm exists" \
    "[ -c /dev/kvm ]"

check "libvirt service active" \
    "systemctl is-active --quiet libvirtd"

check "virsh works without sudo" \
    "virsh list --all"

check "No remaining virtual machines" \
    "[ -z \"\$(virsh list --all --name | tr -d '[:space:]')\" ]"


check "Time synchronized" \
    "timedatectl show -p NTPSynchronized --value | grep -q yes"

# ----------------------------------------
# Result
# ----------------------------------------

echo
echo "========================================"
echo " Post Check Result"
echo " PASS: $PASS"
echo " FAIL: $FAIL"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    echo "[X] Stage 0 post-check FAILED"
    exit 1
fi

echo "[O] Stage 0 post-check PASSED"
exit 0