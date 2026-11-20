#!/usr/bin/env bash
# stage5/preflight.sh — 5단계 실행 전 점검. 읽기 전용. kubeconfig·clouds.yaml 의 내용은 출력하지 않는다.
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage5 preflight
KUBECTL="$BIN_DIR/kubectl"; OSC="$KOLLA_VENV/bin/openstack"; CFG="$KOLLA_CONFIG_DIR/clouds.yaml"
wk() { "$KUBECTL" --kubeconfig "$CLUSTER_KUBECONFIG" "$@" 2>/dev/null || true; }
os() { OS_CLIENT_CONFIG_FILE="$CFG" timeout 60 "$OSC" --os-cloud "$KOLLA_CLOUD" "$@" 2>/dev/null || true; }
log_info "5단계 사전 점검을 시작합니다 (로그: $KIT_LOG_FILE)"

[[ "$(id -u)" -ne 0 ]] && check_ok "root 가 아닌 일반 계정" || check_ng "root 가 아닌 일반 계정" "일반 계정" "root" "kubeconfig 소유권이 어긋난다"
cur="$(tool_version kubectl)"; [[ "$cur" == "$KUBECTL_VERSION" ]] && check_ok "kubectl 버전" "$cur" || check_ng "kubectl 버전" "$KUBECTL_VERSION" "${cur:-없음}" "0단계 install 실행"
command -v python3 >/dev/null 2>&1 && check_ok "python3" || check_ng "python3" "있음" "없음" "sudo apt install python3"

# ---------------------------------------------------------------- 4단계 산출물
if [[ -s "$CLUSTER_KUBECONFIG" ]]; then
  check_ok "워크로드 kubeconfig 있음" "$CLUSTER_KUBECONFIG"
  perm="$(stat -c %a "$CLUSTER_KUBECONFIG" 2>/dev/null || echo "?")"
  [[ "$perm" == "600" ]] && check_ok "kubeconfig 권한" "600" || check_warn "kubeconfig 권한이 600 이 아님" "$perm (chmod 600 권장)"
else check_ng "워크로드 kubeconfig 있음" "$CLUSTER_KUBECONFIG" "없음" "4단계 apply 의 kubeconfig 단계"; fi
if timeout 30 "$KUBECTL" --kubeconfig "$CLUSTER_KUBECONFIG" get nodes >/dev/null 2>&1; then check_ok "워크로드 API 서버 접속"
else check_ng "워크로드 API 서버 접속" "응답" "접속 불가" "API Floating IP 6443 도달성(3단계 FORWARD 규칙), 4단계 클러스터 상태"; fi
want=$((CP_REPLICAS + WORKER_REPLICAS)); n="$(wk get nodes --no-headers | wc -l)"
[[ "$n" -eq "$want" ]] && check_ok "노드 수" "$n" || check_ng "노드 수" "$want" "$n" "4단계 cluster_wait 가 끝나야 한다"
for sg in "k8s-cluster-default-${CLUSTER_NAME}-secgroup-controlplane" "k8s-cluster-default-${CLUSTER_NAME}-secgroup-worker"; do
  [[ -n "$(os security group show "$sg" -c id -f value)" ]] && check_ok "CAPO 보안 그룹" "$sg" || check_ng "CAPO 보안 그룹: $sg" "있음" "없음" "4단계로 클러스터를 만들면 CAPO 가 만든다"
done
[[ -r "$CFG" ]] && check_ok "파일 읽기 가능" "$CFG" || check_ng "파일 읽기 가능: $CFG" "읽기 가능" "불가" "1단계 post-deploy"
grep -qE "^[[:space:]]+${KOLLA_CLOUD}:" "$CFG" 2>/dev/null && check_ok "clouds.yaml 의 cloud" "$KOLLA_CLOUD" || check_ng "clouds.yaml 의 cloud" "$KOLLA_CLOUD" "없음" "OCCM 설정을 만들 수 없다"
for k in auth_url username password project_name user_domain_name region_name; do
  awk -v c="  ${KOLLA_CLOUD}:" '$0==c{f=1;next} /^  [^ ]/{f=0} f' "$CFG" 2>/dev/null | grep -qE "^[[:space:]]+${k}:[[:space:]]*[^[:space:]]" \
    && check_ok "clouds.yaml 항목" "$k" || check_ng "clouds.yaml 항목: $k" "값 있음" "없음" "OCCM cloud.conf 생성에 필요(값은 출력하지 않는다)"
done

# ---------------------------------------------------------------- 인터넷
for u in "$CALICO_BASE_URL/tigera-operator.yaml" "$OCCM_BASE_URL/openstack-cloud-controller-manager-ds.yaml"; do
  c="$(http_code "$u")"; [[ "$c" =~ ^(200|301|302)$ ]] && check_ok "접속" "$(basename "$u") HTTP $c" || check_ng "접속: $u" "응답 있음" "HTTP ${c:-없음}" "raw.githubusercontent.com 접근 확인"
done

# ---------------------------------------------------------------- 알림
[[ -n "$(wk get ds openstack-cloud-controller-manager -n kube-system -o name)" ]] && check_warn "OCCM 이 이미 있음" "apply.sh 는 준비 상태만 확인한다"
[[ -n "$(wk get crd -o name | grep projectcalico || true)" ]] && check_warn "Calico CRD 가 이미 있음" "apply.sh 는 중복 생성하지 않는다"

report_summary || die "점검 실패. 위 [FAIL] 항목을 해결한 뒤 다시 실행하세요." "$EXIT_FAIL"
log_done "5단계 사전 점검 통과"
