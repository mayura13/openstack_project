#!/usr/bin/env bash
# ==============================================================
# stage3/deploy.sh - [3단계] Kubespray로 Kubernetes 설치 실행
# ==============================================================
# Kubespray의 cluster.yml(Kubernetes 설치용 Ansible 플레이북)을 실행합니다. 이 단계가 가장 오래 걸립니다.
# 화면 출력 전체를 logs/stage3-kubespray-<날짜시각>.log 파일에도 저장하고, 걸린 시간을 보여 줍니다.
# 실패하면: 로그 파일에서 "fatal:" 또는 "FAILED" 를 검색해서 어떤 작업이 실패했는지 찾으세요.
# set -euo pipefail : 명령이 하나라도 실패하면 즉시 멈춥니다. (아래에서 설치 실행 구간만 잠시 해제합니다)
set -euo pipefail

# SCRIPT_DIR : 이 파일이 있는 폴더(stage3) / PROJECT_DIR : 프로젝트 맨 위 폴더
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Kubespray 폴더, 사용할 인벤토리, 가상환경의 ansible-playbook 명령 위치
KUBESPRAY_DIR="${HOME}/kubespray"
INVENTORY="${KUBESPRAY_DIR}/inventory/openinfra/inventory.ini"
ANSIBLE_PLAYBOOK="${HOME}/venv-kubespray/bin/ansible-playbook"

# 로그 저장 위치와 파일 이름 (예: logs/stage3-kubespray-20261103-153000.log).
# date '+%Y%m%d-%H%M%S' 는 지금 시각을 "연월일-시분초" 형태로 만듭니다.
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
# 설치 전에 점검 스크립트를 실행합니다. 점검이 실패하면(종료 코드 1) set -e 때문에 여기서 스크립트가 멈춥니다.
# (make stage-3 도 이 앞에서 preflight를 한 번 실행하므로, 설치 직전에 한 번 더 확인하는 셈입니다)
"${SCRIPT_DIR}/preflight.sh"

echo
echo "Starting Kubernetes deployment..."
echo

# 시작 시각(epoch 초) 저장 - 나중에 빼서 걸린 시간을 계산합니다.
START_TIME="$(date +%s)"

# set +e : 잠깐 "실패해도 멈추지 않기"로 바꿉니다.
# 설치가 실패해도 아래에서 걸린 시간 출력과 결과 기록을 마치고, 실패 코드를 그대로 전달하기 위해서입니다.
set +e

# 괄호 ( ) 는 하위 쉘이라 cd 가 이 안에서만 적용됩니다. Kubespray 폴더에서 실행해야 하기 때문입니다.
# 끝의 `2>&1 | tee 파일` 은 오류 출력을 일반 출력과 합쳐 화면에 보여 주면서 동시에 파일로 저장합니다.
(
    cd "${KUBESPRAY_DIR}"
    # ansible-playbook -i <인벤토리> --become cluster.yml
    #   -i       : 사용할 노드 목록   --become : 관리자(root) 권한으로 실행   cluster.yml : Kubernetes 설치 플레이북
    "${ANSIBLE_PLAYBOOK}" \
        -i "${INVENTORY}" \
        --become \
        cluster.yml
) 2>&1 | tee "${LOG_FILE}"

# PIPESTATUS[0] : 파이프 첫 번째 명령(ansible-playbook)의 종료 코드. (tee의 결과가 아니라 설치 결과를 얻기 위해 읽습니다)
PLAYBOOK_STATUS=${PIPESTATUS[0]}

# 다시 "실패하면 즉시 멈추기" 모드로 되돌립니다.
set -e

END_TIME="$(date +%s)"
ELAPSED=$((END_TIME - START_TIME))

# 걸린 시간을 분/초로 나눕니다.
# ※ SECONDS 는 bash가 이미 "스크립트 시작 후 경과 초"로 쓰는 특수 변수라서, 여기서 값을 대입하면 그 값부터 다시 세기 시작합니다.
#   이 스크립트에서는 출력에만 쓰여 문제는 없지만, 다른 이름(예: SEC)을 쓰는 편이 더 안전합니다.
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

echo
echo "========================================"
echo " Stage 3 deployment result"
echo "========================================"
echo "Elapsed time : ${MINUTES}m ${SECONDS}s"
echo "Log          : ${LOG_FILE}"

# 종료 코드가 0이 아니면 실패이므로 같은 코드로 종료해서 make 와 run-deploy.sh 에도 실패를 알립니다.
if [[ "${PLAYBOOK_STATUS}" -ne 0 ]]; then
    echo "[FAIL] Kubespray deployment failed"
    exit "${PLAYBOOK_STATUS}"
fi

echo "[PASS] Kubespray deployment completed"
