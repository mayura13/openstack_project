#!/usr/bin/env bash
# stage5/verify-bcde.sh — 검증 b~e. 시험 자원은 전용 네임스페이스(TEST_NS)에만 만들고 끝나면 항상 지운다.
#   b 노드 3개가 OpenStack 서버와 대응, c 파드·잡 정상, d 파드 간·Service·DNS 통신, e providerID/IP 일치
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage5 verify-bcde
KUBECTL="$BIN_DIR/kubectl"; OSC="$KOLLA_VENV/bin/openstack"; CFG="$KOLLA_CONFIG_DIR/clouds.yaml"
wk() { "$KUBECTL" --kubeconfig "$CLUSTER_KUBECONFIG" "$@" 2>/dev/null || true; }
wkq() { "$KUBECTL" --kubeconfig "$CLUSTER_KUBECONFIG" "$@"; }
os() { OS_CLIENT_CONFIG_FILE="$CFG" timeout 60 "$OSC" --os-cloud "$KOLLA_CLOUD" "$@" 2>/dev/null || true; }
cleanup() { "$KUBECTL" --kubeconfig "$CLUSTER_KUBECONFIG" delete ns "$TEST_NS" --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT
log_info "검증 b~e 를 시작합니다 (로그: $KIT_LOG_FILE)"
want=$((CP_REPLICAS + WORKER_REPLICAS))

timeout 30 "$KUBECTL" --kubeconfig "$CLUSTER_KUBECONFIG" get nodes >/dev/null 2>&1 || { check_ng "워크로드 API 서버 접속" "응답" "접속 불가" "4단계"; report_summary || true; die "접속 불가" "$EXIT_FAIL"; }

# ---------------------------------------------------------------- b
log_step "== 검증 b: 노드와 서버"
servers="$(os server list -f json -c ID -c Name -c Status)"
act="$(python3 -c 'import sys,json
try: d=json.loads(sys.stdin.read() or "[]")
except Exception: d=[]
print(sum(1 for s in d if s.get("Name","").startswith(sys.argv[1]) and s.get("Status")=="ACTIVE"))' "$CLUSTER_NAME" <<<"$servers")"
[[ "$act" -eq "$want" ]] && check_ok "OpenStack 서버 ACTIVE" "${act}대" || check_ng "OpenStack 서버 ACTIVE" "${want}대" "${act}대" "openstack server list"
rdy="$(wk get nodes --no-headers | awk '$2=="Ready"' | wc -l)"
[[ "$rdy" -eq "$want" ]] && check_ok "Ready 노드" "${rdy}/${want}" || check_ng "Ready 노드" "${want}/${want}" "${rdy}/${want}" "stage5/postcheck.sh"

# ---------------------------------------------------------------- c
log_step "== 검증 c: 파드와 잡"
badp="$(wk get pods -A --no-headers | awk '{split($3,a,"/"); if ($4=="Completed"||$4=="Succeeded") next; if ($4!="Running" || a[1]!=a[2]) print $1"/"$2}' | tr '\n' ' ')"
[[ -z "${badp// }" ]] && check_ok "모든 파드 Running 이고 Ready" || check_ng "정상이 아닌 파드" "없음" "$badp" "kubectl describe pod"
jobs="$(wk get jobs -A --no-headers | wc -l)"
if [[ "$jobs" -eq 0 ]]; then check_ok "잡 상태" "대상 없음"
else
  nc="$(wk get jobs -A --no-headers | awk '{split($3,a,"/"); if (a[1]!=a[2]) print $1"/"$2}' | tr '\n' ' ')"
  [[ -z "${nc// }" ]] && check_ok "모든 잡 Complete" "${jobs}개" || check_ng "미완료 잡" "없음" "$nc" "kubectl describe job"
fi

# ---------------------------------------------------------------- d
log_step "== 검증 d: 파드 간 통신, Service, DNS (네임스페이스 ${TEST_NS})"
mapfile -t workers < <(wk get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
if [[ "${#workers[@]}" -lt 2 ]]; then check_ng "워커 노드 2개 이상" "2" "${#workers[@]}" "WORKER_REPLICAS 확인"
else
  wk delete ns "$TEST_NS" --wait=true >/dev/null
  if wkq create ns "$TEST_NS" >/dev/null 2>&1 \
     && cat <<YAML | wkq -n "$TEST_NS" apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: web, labels: {app: web}}
spec:
  nodeName: ${workers[0]}
  tolerations: [{operator: Exists}]
  containers: [{name: nginx, image: "${TEST_NGINX_IMAGE}", ports: [{containerPort: 80}]}]
---
apiVersion: v1
kind: Pod
metadata: {name: client}
spec:
  nodeName: ${workers[1]}
  tolerations: [{operator: Exists}]
  containers: [{name: bb, image: "${TEST_BUSYBOX_IMAGE}", command: ["sleep","3600"]}]
---
apiVersion: v1
kind: Service
metadata: {name: web}
spec: {selector: {app: web}, ports: [{port: 80, targetPort: 80}]}
YAML
  then
    if wkq -n "$TEST_NS" wait --for=condition=Ready pod/web pod/client --timeout=240s >/dev/null 2>&1; then check_ok "시험 파드 2개 Ready" "${workers[0]}, ${workers[1]}"
    else check_ng "시험 파드 2개 Ready" "Ready" "시간 초과" "이미지 내려받기(Docker Hub 등) 가능 여부, kubectl -n $TEST_NS describe pod"; fi
    podip="$(wk -n "$TEST_NS" get pod web -o jsonpath='{.status.podIP}')"
    cip="$(wk -n "$TEST_NS" get svc web -o jsonpath='{.spec.clusterIP}')"
    if [[ -n "$podip" ]] && wkq -n "$TEST_NS" exec client -- wget -qO- -T 5 "http://$podip" 2>/dev/null | grep -q "nginx"; then check_ok "다른 노드 파드 IP 로 HTTP" "$podip"
    else check_ng "다른 노드 파드 IP 로 HTTP" "nginx 응답" "실패" "Typha ${TYPHA_PORT}/tcp 규칙, IPIP(프로토콜 4) 허용, calico-node 로그"; fi
    wkq -n "$TEST_NS" exec client -- nslookup "$cip" >/dev/null 2>&1 || true
    if wkq -n "$TEST_NS" exec client -- nslookup web."$TEST_NS".svc.cluster.local 2>/dev/null | grep -q "$cip"; then check_ok "Service 이름 DNS 조회" "web.$TEST_NS → $cip"
    else check_ng "Service 이름 DNS 조회" "$cip" "실패" "coredns 파드와 노드 간 UDP 통신 확인"; fi
    if wkq -n "$TEST_NS" exec client -- wget -qO- -T 5 "http://web.$TEST_NS" 2>/dev/null | grep -q "nginx"; then check_ok "Service 이름으로 HTTP" "web.$TEST_NS"
    else check_ng "Service 이름으로 HTTP" "nginx 응답" "실패" "kube-proxy 와 Service 엔드포인트 확인"; fi
  else check_ng "시험 자원 생성" "생성됨" "실패" "kubectl -n $TEST_NS get events"; fi
fi

# ---------------------------------------------------------------- e
log_step "== 검증 e: providerID 와 IP 가 OpenStack 서버와 일치"
res="$(for n in $(wk get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  pid="$(wk get node "$n" -o jsonpath='{.spec.providerID}')"; ip="$(wk get node "$n" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
  sj="$(os server show "$n" -f json -c id -c addresses)"
  python3 -c '
import sys, json
n, pid, ip = sys.argv[1:4]
try: d = json.loads(sys.stdin.read() or "{}")
except Exception: d = {}
sid = d.get("id", ""); ad = d.get("addresses", {}); ips = []
if isinstance(ad, dict):
    for v in ad.values(): ips += v if isinstance(v, list) else [v]
elif isinstance(ad, list):
    for e in ad: ips += e.get("addr", []) if isinstance(e.get("addr"), list) else [e.get("addr")]
else: ips = [str(ad)]
ok_pid = bool(sid) and pid == "openstack:///" + sid
ok_ip = ip in [str(x) for x in ips]
print(n, "providerID", "OK" if ok_pid else "NG", "IP", "OK" if ok_ip else "NG")' "$n" "$pid" "$ip" <<<"$sj"
done)"
while read -r n _ a _ b; do
  [[ -n "$n" ]] || continue
  [[ "$a" == "OK" ]] && check_ok "providerID 일치" "$n" || check_ng "providerID 일치: $n" "openstack:///<서버 ID>" "불일치" "OCCM 이 초기화하지 못했거나 서버 이름이 노드 이름과 다르다"
  [[ "$b" == "OK" ]] && check_ok "InternalIP 일치" "$n" || check_ng "InternalIP 일치: $n" "서버의 k8s-net IP" "불일치" "openstack server show $n"
done <<<"$res"
[[ -n "$res" ]] || check_ng "노드 조회" "노드 있음" "없음" "stage5/postcheck.sh"

report_summary || die "검증 실패. 위 [FAIL] 항목을 확인하세요." "$EXIT_FAIL"
log_done "검증 b~e 통과"
