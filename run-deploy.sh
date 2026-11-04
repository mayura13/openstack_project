#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $0 [--from-stage N] <run-id>"
    echo "Example: $0 run-01                  # Stage 0 ~ 6 전체 실행"
    echo "         $0 --from-stage 1 run-02   # Stage 1 ~ 6 만 실행 (0단계 생략)"
}

# 인자 해석: --from-stage N (0~6, 생략하면 0 = 처음부터) 과 <run-id> 하나를 받습니다.
# 옵션 없이 "run-deploy.sh run-01" 로 실행하던 기존 방식은 그대로 동작합니다.
FROM_STAGE=0
RUN_ID=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --from-stage)
            if [ "$#" -lt 2 ]; then
                usage
                exit 1
            fi
            FROM_STAGE="$2"
            shift 2
            ;;
        --from-stage=*)
            FROM_STAGE="${1#--from-stage=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "[FAIL] Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            if [ -n "${RUN_ID}" ]; then
                usage
                exit 1
            fi
            RUN_ID="$1"
            shift
            ;;
    esac
done

if [ -z "${RUN_ID}" ]; then
    usage
    exit 1
fi

if ! [[ "${FROM_STAGE}" =~ ^[0-6]$ ]]; then
    echo "[FAIL] --from-stage must be a number from 0 to 6 (got: ${FROM_STAGE})"
    exit 1
fi

RUN_DIR="${PROJECT_ROOT}/logs/${RUN_ID}"
DEPLOY_LOG="${RUN_DIR}/deploy.log"
TIMING_FILE="${RUN_DIR}/timing.txt"

# 6단계(검증, 상태 수집) 결과도 회차 폴더 안에 저장해서 회차끼리 섞이지 않게 합니다.
EVAL_DIR="${RUN_DIR}/evaluation"

if [ -e "${RUN_DIR}" ]; then
    echo "[FAIL] Run directory already exists: ${RUN_DIR}"
    echo "[INFO] Use a new run ID to avoid overwriting previous results."
    exit 1
fi

mkdir -p "${RUN_DIR}"

# 0단계부터면 기존과 같은 make deploy, 1단계 이상이면 make deploy-from 으로 해당 단계부터 실행합니다.
if [ "${FROM_STAGE}" -eq 0 ]; then
    MAKE_ARGS=(deploy "EVAL_DIR=${EVAL_DIR}")
else
    MAKE_ARGS=(deploy-from "FROM_STAGE=${FROM_STAGE}" "EVAL_DIR=${EVAL_DIR}")
fi

START_EPOCH="$(date +%s)"
START_TIME="$(date --iso-8601=seconds)"

echo "========================================"
echo " OpenInfra Lab Kit Deployment"
echo " Run ID: ${RUN_ID}"
echo "========================================"
echo
echo "[INFO] Log: ${DEPLOY_LOG}"
echo "[INFO] Stages: ${FROM_STAGE} ~ 6"
echo "[INFO] Evaluation output: ${EVAL_DIR}"
echo "[INFO] Started: ${START_TIME}"
echo

set +e
(
    cd "${PROJECT_ROOT}"
    make "${MAKE_ARGS[@]}"
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
from_stage=${FROM_STAGE}
eval_dir=${EVAL_DIR}
TIMING

echo
echo "========================================"
echo " Deployment Result"
echo "========================================"
echo "Run ID:   ${RUN_ID}"
echo "Stages:   ${FROM_STAGE} ~ 6"
echo "Exit code: ${DEPLOY_STATUS}"
echo "Duration:  ${DURATION_SECONDS} seconds"
echo "Log:       ${DEPLOY_LOG}"
echo "Timing:    ${TIMING_FILE}"
echo "Eval:      ${EVAL_DIR}"

if [ "${DEPLOY_STATUS}" -ne 0 ]; then
    echo "[FAIL] Deployment failed."
    exit "${DEPLOY_STATUS}"
fi

echo "[PASS] Deployment completed successfully."
