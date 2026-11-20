#!/usr/bin/env bash
# ==============================================================
# stage4/prepare.sh - [4단계] kubectl/Helm/OpenStack-Helm 소스 준비
# ==============================================================
# 하는 일
#   1) 4단계 preflight 실행
#   2) 내 서버에서 kubectl 이 클러스터에 접속할 수 있게 kubeconfig(~/.kube/config) 만들기
#   3) OpenStack-Helm Helm 저장소 등록
#   4) osh Helm 플러그인 설치 (OpenStack 차트용 보조 명령 helm osh ...)
#   5) OpenStack-Helm 소스 코드를 정해진 버전(태그+커밋)으로 ~/openstack-helm 에 내려받기
# make stage-4 의 첫 단계입니다. 여러 번 실행해도 안전합니다.
# set -euo pipefail : 명령이 하나라도 실패하면 즉시 멈춥니다.
set -euo pipefail

# ROOT_DIR : 프로젝트 맨 위 폴더 / STAGE4_DIR : stage4 폴더
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE4_DIR="${ROOT_DIR}/stage4"

# chart-versions.env 에서 OSH_TAG(OpenStack-Helm 버전), OSH_COMMIT(고정 커밋) 등을 불러옵니다.
source "${STAGE4_DIR}/chart-versions.env"

# KUBECONFIG_PATH : kubectl 이 기본으로 읽는 접속 정보 파일 / OSH_DIR : OpenStack-Helm 소스를 둘 폴더
KUBECONFIG_PATH="${HOME}/.kube/config"
OSH_DIR="${HOME}/openstack-helm"

echo "=== Stage 4 Prepare ==="


# 2. Configure kubeconfig from control-plane
echo
echo "[INFO] Configuring kubeconfig..."

mkdir -p "${HOME}/.kube"

# kubeconfig 만들기. kubeconfig = kubectl 이 "어느 클러스터에 어떤 인증으로 접속할지" 적은 파일입니다.
# cp 노드(192.168.100.10)의 /etc/kubernetes/admin.conf (관리자 접속 정보)를 SSH로 읽어서 ~/.kube/config 로 저장합니다.
# 그러면 이 서버에서 kubectl 과 helm 을 바로 쓸 수 있습니다.
#   -o StrictHostKeyChecking=no, UserKnownHostsFile=/dev/null : 서버 지문 확인/기록을 하지 않음 (VM을 자주 다시 만들기 때문)
# Download kubeconfig to a temporary file first.
# Preserve the existing config if SSH or download fails.
TEMP_KUBECONFIG="$(mktemp "${HOME}/.kube/config.tmp.XXXXXX")"

if ! ssh \
    -i "${HOME}/.ssh/id_vm_ed25519" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes \
    kit@192.168.100.10 \
    'sudo -n cat /etc/kubernetes/admin.conf' \
    > "${TEMP_KUBECONFIG}"; then

    rm -f "${TEMP_KUBECONFIG}"
    echo "[FAIL] Failed to fetch kubeconfig from control-plane"
    exit 1
fi

if [[ ! -s "${TEMP_KUBECONFIG}" ]] ||
   ! kubectl config view \
       --kubeconfig="${TEMP_KUBECONFIG}" \
       -o json >/dev/null 2>&1; then

    rm -f "${TEMP_KUBECONFIG}"
    echo "[FAIL] Downloaded kubeconfig is empty or invalid"
    exit 1
fi

chmod 600 "${TEMP_KUBECONFIG}"
mv -f "${TEMP_KUBECONFIG}" "${KUBECONFIG_PATH}"

echo "[PASS] kubeconfig synchronized"

# Validate the cluster using the freshly synchronized kubeconfig.
"${STAGE4_DIR}/preflight.sh"

# 3. Configure OpenStack-Helm repository
echo "[INFO] Configuring OpenStack-Helm repository..."

# openstack-helm 이름의 Helm 저장소가 이미 있으면 지우고 다시 추가합니다. (주소가 바뀐 경우를 대비)
if helm repo list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "openstack-helm"; then
    helm repo remove openstack-helm >/dev/null
fi

# helm repo add : OpenStack-Helm 차트가 들어 있는 저장소를 등록합니다. (차트 = Helm으로 설치하는 프로그램 묶음)
helm repo add \
    openstack-helm \
    https://tarballs.opendev.org/openstack/openstack-helm

# helm repo update : 등록한 저장소의 차트 목록을 최신으로 갱신합니다.
helm repo update

# 4. Install osh Helm plugin when missing
echo "[INFO] Checking osh Helm plugin..."

# osh 플러그인이 이미 설치되어 있으면 건너뜁니다.
if helm plugin list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "osh"; then
    echo "[PASS] osh plugin already installed"
else
    # helm plugin install : OpenStack-Helm 전용 보조 명령(helm osh ...)을 설치합니다. 5단계 deploy.sh 가 사용합니다.
    helm plugin install \
        https://opendev.org/openstack/openstack-helm-plugin
fi

# 5. Prepare pinned OpenStack-Helm source
echo "[INFO] Preparing OpenStack-Helm ${OSH_TAG}..."

# OpenStack-Helm 소스 폴더 확인.
# 이미 있고 커밋이 고정값(OSH_COMMIT)과 같으면 그대로 사용하고, 다르거나 Git 폴더가 아니면 지우고 다시 받습니다.
if [ -d "${OSH_DIR}" ]; then
    if [ -d "${OSH_DIR}/.git" ]; then
        CURRENT_COMMIT="$(git -C "${OSH_DIR}" rev-parse HEAD)"

        if [ "${CURRENT_COMMIT}" = "${OSH_COMMIT}" ]; then
            echo "[PASS] OpenStack-Helm source already matches ${OSH_TAG}"
        else
            echo "[INFO] Existing source does not match pinned commit."
            # ※ ~/openstack-helm 폴더를 지우고 다시 받습니다. 이 폴더를 직접 수정했다면 사라집니다.
            rm -rf "${OSH_DIR}"
        fi
    else
        echo "[INFO] Removing non-Git OpenStack-Helm directory."
        rm -rf "${OSH_DIR}"
    fi
fi

if [ ! -d "${OSH_DIR}/.git" ]; then
    # git clone --branch <태그> --depth 1 : 지정한 버전(태그)만, 최신 커밋 1개 분량만 내려받습니다(빠르고 가벼움).
    git clone \
        --branch "${OSH_TAG}" \
        --depth 1 \
        https://opendev.org/openstack/openstack-helm.git \
        "${OSH_DIR}"
fi

# 내려받은 코드가 정확히 고정한 커밋인지 확인하고, 다르면 중단합니다. (같은 태그가 다른 내용을 가리키는 사고를 막는 안전장치)
ACTUAL_COMMIT="$(git -C "${OSH_DIR}" rev-parse HEAD)"

if [ "${ACTUAL_COMMIT}" != "${OSH_COMMIT}" ]; then
    echo "[FAIL] OpenStack-Helm commit mismatch"
    echo "Expected: ${OSH_COMMIT}"
    echo "Actual:   ${ACTUAL_COMMIT}"
    exit 1
fi

echo
echo "[PASS] kubeconfig configured"
echo "[PASS] OpenStack-Helm repository configured"
echo "[PASS] osh plugin available"
echo "[PASS] OpenStack-Helm ${OSH_TAG} (${OSH_COMMIT}) ready"
echo
echo "Stage 4 prepare complete."
