#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POSTCHECK="${SCRIPT_DIR}/postcheck.sh"

# Maximum wait: 20 minutes
TIMEOUT_SECONDS=1200
INTERVAL_SECONDS=30

START_TIME="$(date +%s)"
ATTEMPT=0

echo "========================================"
echo " Stage 5 - Waiting for OpenStack readiness"
echo "========================================"

while true; do
    ATTEMPT=$((ATTEMPT + 1))

    echo
    echo "[INFO] Readiness check attempt ${ATTEMPT}"

    if bash "${POSTCHECK}"; then
        echo
        echo "[PASS] All Stage 5 readiness checks passed"
        exit 0
    fi

    NOW="$(date +%s)"
    ELAPSED=$((NOW - START_TIME))

    if (( ELAPSED >= TIMEOUT_SECONDS )); then
        echo
        echo "[FAIL] OpenStack did not become ready within ${TIMEOUT_SECONDS}s"
        exit 1
    fi

    REMAINING=$((TIMEOUT_SECONDS - ELAPSED))
    SLEEP_SECONDS=$((INTERVAL_SECONDS < REMAINING ? INTERVAL_SECONDS : REMAINING))

    echo "[INFO] Not ready yet (${ELAPSED}s elapsed). Retrying in ${SLEEP_SECONDS}s..."
    sleep "${SLEEP_SECONDS}"
done
