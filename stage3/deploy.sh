#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

KUBESPRAY_DIR="${HOME}/kubespray"
INVENTORY="${KUBESPRAY_DIR}/inventory/openinfra/inventory.ini"
ANSIBLE_PLAYBOOK="${HOME}/venv-kubespray/bin/ansible-playbook"

LOG_DIR="${PROJECT_DIR}/logs"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_FILE="${LOG_DIR}/stage3-kubespray-${TIMESTAMP}.log"

mkdir -p "${LOG_DIR}"

echo "========================================"
echo " Stage 3 - Kubernetes Deployment"
echo "========================================"
echo "Kubespray : ${KUBESPRAY_DIR}"
echo "Inventory : ${INVENTORY}"
echo "Log       : ${LOG_FILE}"
echo

# 배포 전 검증
"${SCRIPT_DIR}/preflight.sh"

echo
echo "Starting Kubernetes deployment..."
echo

START_TIME="$(date +%s)"

set +e

(
    cd "${KUBESPRAY_DIR}"
    "${ANSIBLE_PLAYBOOK}" \
        -i "${INVENTORY}" \
        --become \
        cluster.yml
) 2>&1 | tee "${LOG_FILE}"

PLAYBOOK_STATUS=${PIPESTATUS[0]}

set -e

END_TIME="$(date +%s)"
ELAPSED=$((END_TIME - START_TIME))

MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

echo
echo "========================================"
echo " Stage 3 deployment result"
echo "========================================"
echo "Elapsed time : ${MINUTES}m ${SECONDS}s"
echo "Log          : ${LOG_FILE}"

if [[ "${PLAYBOOK_STATUS}" -ne 0 ]]; then
    echo "[FAIL] Kubespray deployment failed"
    exit "${PLAYBOOK_STATUS}"
fi

echo "[PASS] Kubespray deployment completed"
