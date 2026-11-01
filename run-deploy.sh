#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <run-id>"
    echo "Example: $0 run-01"
    exit 1
fi

RUN_ID="$1"
RUN_DIR="${PROJECT_ROOT}/logs/${RUN_ID}"
DEPLOY_LOG="${RUN_DIR}/deploy.log"
TIMING_FILE="${RUN_DIR}/timing.txt"

if [ -e "${RUN_DIR}" ]; then
    echo "[FAIL] Run directory already exists: ${RUN_DIR}"
    echo "[INFO] Use a new run ID to avoid overwriting previous results."
    exit 1
fi

mkdir -p "${RUN_DIR}"

START_EPOCH="$(date +%s)"
START_TIME="$(date --iso-8601=seconds)"

echo "========================================"
echo " OpenInfra Lab Kit Deployment"
echo " Run ID: ${RUN_ID}"
echo "========================================"
echo
echo "[INFO] Log: ${DEPLOY_LOG}"
echo "[INFO] Started: ${START_TIME}"
echo

set +e
(
    cd "${PROJECT_ROOT}"
    make deploy
) 2>&1 | tee "${DEPLOY_LOG}"

DEPLOY_STATUS=${PIPESTATUS[0]}
set -e

END_EPOCH="$(date +%s)"
END_TIME="$(date --iso-8601=seconds)"
DURATION_SECONDS=$((END_EPOCH - START_EPOCH))

cat > "${TIMING_FILE}" <<TIMING
run_id=${RUN_ID}
start_time=${START_TIME}
end_time=${END_TIME}
duration_seconds=${DURATION_SECONDS}
exit_code=${DEPLOY_STATUS}
TIMING

echo
echo "========================================"
echo " Deployment Result"
echo "========================================"
echo "Run ID:   ${RUN_ID}"
echo "Exit code: ${DEPLOY_STATUS}"
echo "Duration:  ${DURATION_SECONDS} seconds"
echo "Log:       ${DEPLOY_LOG}"
echo "Timing:    ${TIMING_FILE}"

if [ "${DEPLOY_STATUS}" -ne 0 ]; then
    echo "[FAIL] Deployment failed."
    exit "${DEPLOY_STATUS}"
fi

echo "[PASS] Deployment completed successfully."
