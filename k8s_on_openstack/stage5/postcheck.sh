#!/usr/bin/env bash
# stage5/postcheck.sh — 5단계 완료 후 점검. 읽기 전용. Secret 값은 해시로만 비교한다.
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage5 postcheck
KUBECTL="$BIN_DIR/kubectl"; OSC="$KOLLA_VENV/bin/openstack"; CFG="$KOLLA_CONFIG_DIR/clouds.yaml"
wk() { "$KUBECTL" --kubeconfig "$CLUSTER_KUBECONFIG" "$@" 2>/dev/null || true; }
os() { OS_CLIENT_CONFIG_FILE="$CFG" timeout 60 "$OSC" --os-cloud "$KOLLA_CLOUD" "$@" 2>/dev/null || true; }
log_info "5단계 사후 점검을 시작합니다 (로그: $KIT_LOG_FILE)"

# ---------------------------------------------------------------- 보안 그룹
CP_SG="k8s-cluster-default-${CLUSTER_NAME}-secgroup-controlplane"; WK_SG="k8s-cluster-default-${CLUSTER_NAME}-secgroup-worker"
cp_id="$(os security group show "$CP_SG" -c id -f value)"; wk_id="$(os security group show "$WK_SG" -c id -f value)"
rules="$(os security group rule list "$WK_SG" --ingress --protocol tcp -f json)"
has_rule() { python3 -c '
import sys, json
rid, port = sys.argv[1], sys.argv[2]
try: rs = json.loads(sys.stdin.read() or "[]")
except Exception: raise SystemExit(1)
raise SystemExit(0 if any(str(r.get("Port Range") or "") in (port, port+":"+port) and (r.get("Remote Security Group") or "") == rid for r in rs) else 1)' "$1" "$TYPHA_PORT" <<<"$rules"; }
[[ -n "$cp_id" ]] && has_rule "$cp_id" && check_ok "Typha ${TYPHA_PORT}/tcp 규칙(출발지 컨트롤플레인 SG)" || check_ng "Typha ${TYPHA_PORT}/tcp 규칙(출발지 컨트롤플레인 SG)" "있음" "없음" "apply.sh 의 typha_sg 단계. CAPO 가 규칙을 되돌렸는지도 확인"
[[ -n "$wk_id" ]] && has_rule "$wk_id" && check_ok "Typha ${TYPHA_PORT}/tcp 규칙(출발지 워커 SG)" || check_ng "Typha ${TYPHA_PORT}/tcp 규칙(출발지 워커 SG)" "있음" "없음" "apply.sh 의 typha_sg 단계"

# ---------------------------------------------------------------- OCCM
ready="$(wk -n kube-system get ds openstack-cloud-controller-manager -o jsonpath='{.status.numberReady}')"
desired="$(wk -n kube-system get ds openstack-cloud-controller-manager -o jsonpath='{.status.desiredNumberScheduled}')"
[[ "$ready" =~ ^[1-9][0-9]*$ && "$ready" == "$desired" ]] && check_ok "OCCM DaemonSet 준비" "${ready}/${desired}" || check_ng "OCCM DaemonSet 준비" "전부 준비" "${ready:-0}/${desired:-?}" "kubectl describe ds/openstack-cloud-controller-manager -n kube-system"
img="$(wk -n kube-system get ds openstack-cloud-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}')"
[[ "$img" == *":${OCCM_VERSION}" ]] && check_ok "OCCM 이미지 버전" "${img##*:}" || check_ng "OCCM 이미지 버전" "$OCCM_VERSION" "${img:-없음}" "태그 고정이 풀렸다"
lb="$(wk -n kube-system get secret cloud-config -o jsonpath='{.data.cloud\.conf}' | base64 -d 2>/dev/null | grep -c '^enabled=false$' || true)"
[[ "$lb" -ge 1 ]] && check_ok "cloud-config Secret 에 LoadBalancer enabled=false" || check_ng "cloud-config Secret 에 LoadBalancer enabled=false" "있음" "없음" "Octavia 가 없으면 필수. apply.sh 의 occm_secret 단계"

# ---------------------------------------------------------------- Calico
ts="$(wk get tigerastatus -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="Available")]}{.status}{end}{"\n"}{end}')"
for name in $CALICO_EXPECTED_STATUS; do grep -qx "$name True" <<<"$ts" && check_ok "tigerastatus" "$name Available" || check_ng "tigerastatus: $name" "Available" "아님" "kubectl get tigerastatus; describe 로 원인 확인"; done
enc="$(wk get ippool default-ipv4-ippool -o jsonpath='{.spec.ipipMode}')"
[[ "$CALICO_ENCAP" == "IPIP" ]] && { [[ "$enc" == "Always" || "$enc" == "CrossSubnet" ]] && check_ok "IPPool 캡슐화" "ipipMode=$enc" || check_ng "IPPool 캡슐화" "IPIP" "ipipMode=${enc:-없음}" "custom-resources 의 encapsulation 값 확인"; }
cidr="$(wk get ippool default-ipv4-ippool -o jsonpath='{.spec.cidr}')"
[[ "$cidr" == "$POD_CIDR" ]] && check_ok "IPPool CIDR" "$cidr" || check_ng "IPPool CIDR" "$POD_CIDR" "${cidr:-없음}" "클러스터 podCIDR 과 같아야 한다"

# ---------------------------------------------------------------- 노드·파드
want=$((CP_REPLICAS + WORKER_REPLICAS)); nodes="$(wk get nodes --no-headers)"
rdy="$(awk '$2=="Ready"' <<<"$nodes" | wc -l)"
[[ "$rdy" -eq "$want" ]] && check_ok "Ready 노드" "${rdy}/${want}" || check_ng "Ready 노드" "${want}/${want}" "${rdy}/${want}" "CNI(Calico)와 OCCM 상태 확인"
bad="$(wk get nodes -o custom-columns='NAME:.metadata.name,T:.spec.taints[*].key' --no-headers | { grep -E 'network-unavailable|uninitialized|not-ready|unreachable' || true; } | awk '{print $1}' | tr '\n' ' ')"
[[ -z "${bad// }" ]] && check_ok "미해제 테인트 없음" || check_ng "미해제 테인트" "없음" "$bad" "uninitialized 는 OCCM, not-ready 는 CNI"
np="$(wk get nodes -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}' | grep -c '^openstack:///' || true)"
[[ "$np" -eq "$want" ]] && check_ok "providerID(openstack:///)" "${np}개" || check_ng "providerID(openstack:///)" "${want}개" "${np}개" "OCCM 이 노드를 초기화하지 못했다"
badp="$(wk get pods -A --no-headers | awk '{split($3,a,"/"); if ($4=="Completed"||$4=="Succeeded") next; if ($4!="Running" || a[1]!=a[2]) print $1"/"$2}' | tr '\n' ' ')"
[[ -z "${badp// }" ]] && check_ok "모든 파드 Running 이고 Ready" || check_ng "정상이 아닌 파드" "없음" "$badp" "kubectl get pods -A; describe 로 이벤트 확인"

report_summary || die "점검 실패. 위 [FAIL] 항목을 확인하세요." "$EXIT_FAIL"
log_done "5단계 사후 점검 통과"
