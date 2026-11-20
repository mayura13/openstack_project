#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform"
PLAN_FILE="${TERRAFORM_DIR}/stage1.tfplan"

source "${PROJECT_ROOT}/common/common.sh"

print_header "OpenInfra Lab Kit - Stage 1 Apply"

# --------------------------------------------------
# 1. Stage 1 Preflight
# --------------------------------------------------

print_info "Running Stage 1 preflight"

bash "${SCRIPT_DIR}/preflight.sh" || {
    print_error_detail \
        "Stage 1" \
        "Preflight" \
        "Stage 1 prerequisites are not satisfied" \
        "N/A"
    exit 1
}

print_pass "Stage 1 preflight passed"

# --------------------------------------------------
# 2. Prepare image and SSH key
# --------------------------------------------------

print_info "Preparing Ubuntu image and SSH key"

bash "${SCRIPT_DIR}/prepare.sh" || {
    print_error_detail \
        "Stage 1" \
        "Preparation" \
        "Failed to prepare Stage 1 resources" \
        "N/A"
    exit 1
}

print_pass "Stage 1 resources prepared"

# --------------------------------------------------
# 3. Configure AppArmor
# --------------------------------------------------

print_info "Configuring AppArmor for libvirt"

bash "${SCRIPT_DIR}/configure-apparmor.sh" || {
    print_error_detail \
        "Stage 1" \
        "AppArmor" \
        "Failed to configure AppArmor for libvirt" \
        "N/A"
    exit 1
}

print_pass "AppArmor configuration completed"

# --------------------------------------------------
# 4. Terraform init
# --------------------------------------------------

print_info "Running terraform init"

terraform \
    -chdir="${TERRAFORM_DIR}" \
    init || {
        print_error_detail \
            "Stage 1" \
            "Terraform init" \
            "terraform init failed" \
            "N/A"
        exit 1
    }

print_pass "Terraform initialized"

# --------------------------------------------------
# 5. Terraform format check
# --------------------------------------------------

print_info "Checking Terraform formatting"

terraform \
    -chdir="${TERRAFORM_DIR}" \
    fmt \
    -check || {
        print_error_detail \
            "Stage 1" \
            "Terraform fmt" \
            "Terraform files are not correctly formatted" \
            "Run: terraform -chdir=${TERRAFORM_DIR} fmt"
        exit 1
    }

print_pass "Terraform formatting valid"

# --------------------------------------------------
# 6. Terraform validate
# --------------------------------------------------

print_info "Running terraform validate"

terraform \
    -chdir="${TERRAFORM_DIR}" \
    validate || {
        print_error_detail \
            "Stage 1" \
            "Terraform validate" \
            "Terraform configuration validation failed" \
            "N/A"
        exit 1
    }

print_pass "Terraform configuration valid"

# --------------------------------------------------
# 7. Terraform plan
# --------------------------------------------------

print_info "Creating Terraform plan"

rm -f "${PLAN_FILE}"

terraform \
    -chdir="${TERRAFORM_DIR}" \
    plan \
    -out="$(basename "${PLAN_FILE}")" || {
        rm -f "${PLAN_FILE}"

        print_error_detail \
            "Stage 1" \
            "Terraform plan" \
            "Failed to create Terraform execution plan" \
            "N/A"
        exit 1
    }

print_pass "Terraform plan created"

# --------------------------------------------------
# 8. Terraform apply
# --------------------------------------------------

print_info "Applying Terraform plan"

terraform \
    -chdir="${TERRAFORM_DIR}" \
    apply \
    -parallelism=1 \
    "$(basename "${PLAN_FILE}")" || {
        print_error_detail \
            "Stage 1" \
            "Terraform apply" \
            "Terraform failed while creating Stage 1 infrastructure" \
            "Inspect the Terraform output before retrying"
        exit 1
    }

print_pass "Terraform apply completed"

# --------------------------------------------------
# 8-1. Ensure all lab VMs are running
# --------------------------------------------------

print_info "Ensuring all lab VMs are running"

for vm in cp ctrl-worker compute-1 compute-2; do
    state="$(sudo virsh -c qemu:///system domstate "$vm")"

    if [[ "$state" == "running" ]]; then
        print_pass "$vm already running"
    elif [[ "$state" == "shut off" ]]; then
        print_info "Starting $vm"
        sudo virsh -c qemu:///system start "$vm"
    else
        print_error_detail \
            "Stage 1" \
            "VM startup" \
            "$vm is in unexpected state: $state" \
            "Inspect with: sudo virsh -c qemu:///system dominfo $vm"
        exit 1
    fi
done

print_pass "All lab VMs are running"
# --------------------------------------------------
# 9. Generate Ansible inventories
# --------------------------------------------------

print_info "Generating Stage 2 and Stage 3 inventories"

bash "${PROJECT_ROOT}/common/generate-inventory.sh" || {
    print_error_detail \
        "Stage 1" \
        "Inventory generation" \
        "Failed to generate inventories from Terraform output" \
        "Check Terraform node_ips output"
    exit 1
}

print_pass "Stage 2 and Stage 3 inventories generated"

# --------------------------------------------------
# 9-1. Wait for SSH/Ansible connectivity
# --------------------------------------------------

print_info "Waiting for all four VMs to become SSH-ready"

ANSIBLE_BIN="${HOME}/venv-kubespray/bin/ansible"
STAGE2_INVENTORY="${PROJECT_ROOT}/stage2/inventory.ini"
STAGE2_CONFIG="${PROJECT_ROOT}/stage2/ansible.cfg"

if [[ ! -x "${ANSIBLE_BIN}" ]]; then
    echo "[FAIL] Ansible executable not found: ${ANSIBLE_BIN}"
    exit 1
fi

for attempt in $(seq 1 60); do
    if ANSIBLE_CONFIG="${STAGE2_CONFIG}" \
        "${ANSIBLE_BIN}" -i "${STAGE2_INVENTORY}" \
        all -m ping -o -f 4 \
        -e ansible_timeout=3 \
        > /dev/null 2>&1; then
        print_pass "All four VMs are SSH-ready"
        break
    fi

    if [[ "${attempt}" -eq 60 ]]; then
        echo "[FAIL] VM SSH readiness check failed after 60 attempts"
        echo "Check VM IPs, SSH keys and Stage 2 Ansible configuration."
        exit 1
    fi

    sleep 5
done


# --------------------------------------------------
# Complete
# --------------------------------------------------

echo
echo "========================================"
echo " Stage 1 Terraform apply completed"
echo "========================================"
echo

print_info "Run stage1/postcheck.sh to verify the result."
