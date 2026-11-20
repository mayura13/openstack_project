#!/usr/bin/env bash
# stage4/postcheck.sh — 4단계 완료 후 점검. 읽기 전용. kubeconfig 와 Secret 의 내용은 출력하지 않는다.
# 이 단계의 노드는 NotReady 가 정상이다(CNI 는 5단계). Ready 여도 FAIL 로 보지 않는다.
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage4 postcheck
KUBECTL="$BIN_DIR/kubectl"; OSC="$KOLLA_VENV/bin/openstack"; CFG="$KOLLA_CONFIG_DIR/clouds.yaml"
kc() { "$KUBECTL" --context "$KUBE_CONTEXT" "$@" 2>/dev/null || true; }
wk() { "$KUBECTL" --kubeconfig "$CLUSTER_KUBECONFIG" "$@" 2>/dev/null || true; }
os() { OS_CLIENT_CONFIG_FILE="$CFG" timeout 60 "$OSC" --os-cloud "$KOLLA_CLOUD" "$@" 2>/dev/null || true; }
log_info "4단계 사후 점검을 시작합니다 (로그: $KIT_LOG_FILE)"

# ---------------------------------------------------------------- 관리 클러스터 쪽
orc="$(kc -n orc-system get pods --no-headers | awk '{print $2" "$3}' | head -n1)"
[[ "$orc" == "1/1 Running" ]] && check_ok "ORC 컨트롤러 Running" || check_ng "ORC 컨트롤러 Running" "1/1 Running" "${orc:-없음}" "CAPO 가 ORC CRD 없이는 CrashLoop 된다. apply.sh 의 orc 단계"
capo="$(kc -n capo-system get pods --no-headers | awk '{print $2" "$3" "$4}' | head -n1)"
[[ "$capo" == "1/1 Running 0" ]] && check_ok "CAPO 컨트롤러 Running, RESTARTS 0" || {
  [[ "$capo" == 1/1\ Running* ]] && check_warn "CAPO 가 Running 이지만 재시작 이력 있음" "$capo" || check_ng "CAPO 컨트롤러 Running" "1/1 Running 0" "${capo:-없음}" "ORC 설치 뒤 CAPO 재시작 필요"; }
sh="$(kc -n default get secret "$CLOUD_SECRET_NAME" -o jsonpath='{.data.clouds\.yaml}' | base64 -d 2>/dev/null | sha256sum | cut -d' ' -f1 || true)"
fh="$(sha256sum "$CFG" 2>/dev/null | cut -d' ' -f1 || true)"
[[ -n "$sh" && "$sh" == "$fh" ]] && check_ok "인증 Secret 이 clouds.yaml 과 일치(해시 비교)" || check_ng "인증 Secret 이 clouds.yaml 과 일치" "해시 같음" "다름 또는 없음" "비밀번호가 바뀌었으면 apply.sh 의 secret 단계로 갱신"

# ---------------------------------------------------------------- 클러스터 객체
phase="$(kc -n default get cluster "$CLUSTER_NAME" -o jsonpath='{.status.phase}')"
[[ "$phase" == "Provisioned" ]] && check_ok "Cluster phase" "$phase" || check_ng "Cluster phase" "Provisioned" "${phase:-없음}" "apply.sh 로 생성하고 기다린다"
init="$(kc -n default get kubeadmcontrolplane "${CLUSTER_NAME}-control-plane" -o json | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print("false"); raise SystemExit
def f(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k in ("initialized", "controlPlaneInitialized") and isinstance(v, bool): return v
            r = f(v)
            if r is not None: return r
    return None
print("true" if f(d.get("status", {})) else "false")' 2>/dev/null || echo false)"
[[ "$init" == "true" ]] && check_ok "KubeadmControlPlane INITIALIZED" || check_ng "KubeadmControlPlane INITIALIZED" "true" "$init" "kind → 외부망 FORWARD 규칙(3단계), API 서버 Floating IP 6443 도달 여부 확인"
want=$((CP_REPLICAS + WORKER_REPLICAS))
mach="$(kc -n default get machines -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}" -o jsonpath='{range .items[*]}{.status.phase}{" "}{.status.nodeRef.name}{"\n"}{end}' | awk '$1=="Running" && $2!="" {c++} END{print c+0}')"
[[ "$mach" -eq "$want" ]] && check_ok "Machine Running(노드 이름 있음)" "${mach}/${want}" || check_ng "Machine Running(노드 이름 있음)" "${want}/${want}" "${mach}/${want}" "kubectl --context $KUBE_CONTEXT get machine -A, CAPO 로그"
om="$(kc -n default get openstackmachines --no-headers | grep -c . || true)"
[[ "${om:-0}" -eq "$want" ]] && check_ok "OpenStackMachine" "${om}개" || check_ng "OpenStackMachine" "$want" "${om:-0}" "CAPO 가 VM 을 만들지 못했다"

# ---------------------------------------------------------------- OpenStack 쪽 자원
srv="$(os server list -f value -c Name -c Status | grep "^${CLUSTER_NAME}-" || true)"
nsrv="$(grep -c . <<<"$srv" || true)"; nact="$(grep -c ' ACTIVE$' <<<"$srv" || true)"
[[ "${nact:-0}" -eq "$want" && "${nsrv:-0}" -eq "$want" ]] && check_ok "노드 VM ACTIVE" "${nact}/${want}" || check_ng "노드 VM ACTIVE" "${want}/${want}" "${nact:-0}/${nsrv:-0}" "openstack server list 와 nova-compute 로그 확인"
sg="$(os security group list -f value -c Name | grep -c "secgroup-\(controlplane\|worker\)" || true)"
[[ "${sg:-0}" -eq 2 ]] && check_ok "CAPO 관리 보안 그룹" "2개" || check_ng "CAPO 관리 보안 그룹" "2개(controlplane, worker)" "${sg:-0}" "OpenStackCluster 의 managedSecurityGroups 확인"
fip="$(os floating ip list -f value -c 'Floating IP Address' | head -n1)"
[[ -n "$fip" ]] && check_ok "API 서버 Floating IP" "$fip" || check_ng "API 서버 Floating IP" "1개" "없음" "OpenStackCluster apiServer 설정 확인"
nets="$(os network list -f value -c Name | sort | tr '\n' ' ')"
extra="$(tr ' ' '\n' <<<"$nets" | { grep -vxE "$EXT_NET_NAME|$K8S_NET_NAME|" || true; } | tr '\n' ' ')"
[[ -z "${extra// }" ]] && check_ok "Terraform 네트워크 재사용(CAPO 가 새 네트워크를 만들지 않음)" || check_warn "예상 밖의 네트워크" "$extra(주문서의 managedSubnets 가 남아 있으면 새 네트워크가 만들어진다)"

# ---------------------------------------------------------------- API 서버 도달성
if [[ -n "$fip" ]]; then
  c="$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://${fip}:6443/livez" 2>/dev/null || true)"
  [[ "$c" == "200" ]] && check_ok "호스트 → API /livez" "HTTP $c" || check_ng "호스트 → API /livez" "HTTP 200" "HTTP ${c:-없음}" "컨트롤플레인 부팅 중이거나 보안 그룹 6443 확인"
  c="$(docker exec "${KIND_CLUSTER}-control-plane" curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://${fip}:6443/livez" 2>/dev/null || true)"
  [[ "$c" == "200" ]] && check_ok "관리 클러스터 → API /livez" "HTTP $c" || check_ng "관리 클러스터 → API /livez" "HTTP 200" "HTTP ${c:-없음}" "호스트 방화벽 FORWARD 규칙(3단계 nat). 이 경로가 막히면 INITIALIZED 가 비고 워커가 Pending 에 머문다"
fi

# ---------------------------------------------------------------- 워크로드 클러스터(kubeconfig)
if [[ -s "$CLUSTER_KUBECONFIG" ]]; then
  perm="$(stat -c '%a' "$CLUSTER_KUBECONFIG")"
  [[ "$perm" == "600" ]] && check_ok "kubeconfig 권한" "$perm" || check_ng "kubeconfig 권한" "600" "$perm" "chmod 600 $CLUSTER_KUBECONFIG (관리자 인증 정보)"
  nodes="$(wk get nodes --no-headers | awk '{print $1" "$2" "$5}')"
  nn="$(grep -c . <<<"$nodes" || true)"
  [[ "${nn:-0}" -eq "$want" ]] && check_ok "노드 등록" "${nn}/${want}" || check_ng "노드 등록" "${want}/${want}" "${nn:-0}" "kubeadm join 실패 가능. 노드 VM 콘솔 로그 확인"
  badv="$(awk '$3!="'"$K8S_SEMVER"'"{print $1" "$3}' <<<"$nodes" | tr '\n' ' ')"
  [[ -z "${badv// }" && "${nn:-0}" -gt 0 ]] && check_ok "노드 Kubernetes 버전" "$K8S_SEMVER" || check_ng "노드 Kubernetes 버전" "$K8S_SEMVER" "${badv:-노드 없음}" "노드 이미지 버전 확인"
  ready="$(awk '$2=="Ready"{c++} END{print c+0}' <<<"$nodes")"
  if [[ "$ready" -eq 0 ]]; then check_ok "노드 NotReady(이 단계에서 정상)" "CNI 는 5단계"
  else check_ok "노드 Ready ${ready}/${nn}" "CNI 가 이미 설치됨(5단계 이후)"; fi
  disk="$(wk get nodes -o jsonpath='{range .items[*]}{.status.capacity.ephemeral-storage}{"\n"}{end}' | sed 's/Ki$//' | sort -n | head -n1)"
  [[ "${disk:-0}" =~ ^[0-9]+$ && "${disk:-0}" -ge "$MIN_NODE_DISK_KI" ]] && check_ok "노드 디스크가 flavor 크기로 확장됨" "${disk}Ki" || check_ng "노드 디스크가 flavor 크기로 확장됨" ">= ${MIN_NODE_DISK_KI}Ki" "${disk:-확인 불가}" "20GiB 이미지의 루트 디스크가 60GB 로 확장되지 않았다"
else
  check_ng "kubeconfig" "$CLUSTER_KUBECONFIG" "없음" "apply.sh 의 kubeconfig 단계"
fi

report_summary || die "점검 실패. 위 [FAIL] 항목을 해결한 뒤 다시 실행하세요." "$EXIT_FAIL"
log_done "4단계 사후 점검 통과"
