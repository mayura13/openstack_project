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
# Complete
# --------------------------------------------------

echo
echo "========================================"
echo " Stage 1 Terraform apply completed"
echo "========================================"
echo

print_info "Run stage1/postcheck.sh to verify the result."