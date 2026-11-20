#!/usr/bin/env bash
# stage3/postcheck.sh — 3단계 완료 후 점검. 읽기 전용. kubeconfig 내용은 출력하지 않는다.
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage3 postcheck
KUBECTL="$BIN_DIR/kubectl"; KIND="$BIN_DIR/kind"
kc() { "$KUBECTL" --context "$KUBE_CONTEXT" "$@" 2>/dev/null || true; }
log_info "3단계 사후 점검을 시작합니다 (로그: $KIT_LOG_FILE)"

# Docker, kind
if docker ps >/dev/null 2>&1; then check_ok "docker 를 sudo 없이 사용"
else check_ng "docker 를 sudo 없이 사용" "docker ps 성공" "실패" "재로그인(tmux 서버 재시작 포함) 또는 1단계 확인"; fi
if "$KIND" get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then check_ok "kind 클러스터" "$KIND_CLUSTER"
else check_ng "kind 클러스터" "$KIND_CLUSTER" "없음" "apply.sh 의 kind_cluster 단계"; fi
st="$(docker ps --filter "name=^${KIND_CLUSTER}-control-plane$" --format '{{.Status}}' 2>/dev/null || true)"
[[ "$st" == Up* ]] && check_ok "kind 컨테이너 실행" "$st" || check_ng "kind 컨테이너 실행" "Up" "${st:-없음}" "docker start ${KIND_CLUSTER}-control-plane"
sub="$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/' | head -n1 || true)"
[[ "$sub" == "$KIND_NET_CIDR" ]] && check_ok "kind 네트워크 대역" "$sub" || check_ng "kind 네트워크 대역" "$KIND_NET_CIDR" "${sub:-없음}" "NAT/FORWARD 규칙이 다른 대역에 걸려 있다. versions.env 의 KIND_NET_CIDR 갱신 후 apply.sh"

# NAT 와 영속화
NAT_LINE="-s ${KIND_NET_CIDR} -o ${HOST_NIC} -j MASQUERADE"
FWD_LINE="-s ${KIND_NET_CIDR} -d ${EXT_NET_CIDR} -o ${EXT_HOST_IF} -j ACCEPT"
# shellcheck disable=SC2086
sudo -n iptables -t nat -C POSTROUTING $NAT_LINE 2>/dev/null && check_ok "kind NAT(MASQUERADE) 규칙(실시간)" || check_ng "kind NAT(MASQUERADE) 규칙(실시간)" "$NAT_LINE" "없음" "clusterctl init 이 시간 초과된다. apply.sh 의 nat 단계"
# shellcheck disable=SC2086
sudo -n iptables -C FORWARD $FWD_LINE 2>/dev/null && check_ok "kind → 외부망 FORWARD 규칙(실시간)" || check_ng "kind → 외부망 FORWARD 규칙(실시간)" "$FWD_LINE" "없음" "4단계에서 관리 클러스터가 노드 VM 에 닿지 못한다"
for l in "$NAT_LINE" "$FWD_LINE"; do
  sudo -n grep -qF -- "$l" "$HOST_NET_SCRIPT" 2>/dev/null && check_ok "호스트 네트워크 스크립트에 영속화" "${l%% -j*}" || check_ng "호스트 네트워크 스크립트에 영속화: ${l%% -j*}" "스크립트에 줄 있음" "없음" "재부팅하면 규칙이 사라진다. apply.sh 의 nat 단계"
done

# 컨텍스트와 노드
ctxs="$("$KUBECTL" config get-contexts -o name 2>/dev/null | tr '\n' ' ' || true)"
grep -qw -- "$KUBE_CONTEXT" <<<"$ctxs" && check_ok "kubeconfig 컨텍스트" "$KUBE_CONTEXT" || check_ng "kubeconfig 컨텍스트" "$KUBE_CONTEXT" "${ctxs:-없음}" "kind 클러스터 생성 단계"
[[ ! -f "$HOME/.kube/config" ]] || { perm="$(stat -c '%a' "$HOME/.kube/config")"; [[ "$perm" == "600" ]] && check_ok "kubeconfig 권한" "$perm" || check_warn "kubeconfig 권한 $perm" "관리자 인증 정보. chmod 600 권장"; }
node="$(kc get nodes --no-headers | awk '{print $1" "$2" "$5}')"
[[ "$node" == "${KIND_CLUSTER}-control-plane Ready ${MGMT_NODE_VERSION}" ]] && check_ok "관리 클러스터 노드" "$node" || check_ng "관리 클러스터 노드" "${KIND_CLUSTER}-control-plane Ready ${MGMT_NODE_VERSION}" "${node:-조회 실패}" "kind 노드 이미지 digest 확인"

# provider 와 파드
out="$(kc get providers.clusterctl.cluster.x-k8s.io -A --no-headers)"
for p in "cluster-api v${CLUSTERCTL_VERSION}" "bootstrap-kubeadm v${CLUSTERCTL_VERSION}" "control-plane-kubeadm v${CLUSTERCTL_VERSION}" "infrastructure-openstack ${CAPO_VERSION}"; do
  name="${p%% *}"; ver="${p#* }"
  grep -qE "${name}[[:space:]].*${ver}" <<<"$out" && check_ok "provider" "$name $ver" || check_ng "provider: $name" "$ver" "${out:-없음}" "clusterctl init 단계"
done
for ns in $CAPI_NAMESPACES; do
  pods="$(kc -n "$ns" get pods --no-headers)"
  total="$(grep -c . <<<"$pods" || true)"
  bad="$(awk '{split($2,a,"/"); if ($3!="Running" || a[1]!=a[2]) print $1" "$3}' <<<"$pods" | tr '\n' ' ')"
  if [[ "${total:-0}" -gt 0 && -z "${bad// }" ]]; then check_ok "파드 Running" "$ns ${total}개"
  else check_ng "파드 Running: $ns" "전부 Running(n/n)" "${bad:-파드 없음}" "kubectl --context $KUBE_CONTEXT -n $ns describe pods"; fi
done
crds="$(kc get crd -o name)"
for c in openstackclusters openstackmachines openstackmachinetemplates; do
  grep -q "${c}.infrastructure.cluster.x-k8s.io" <<<"$crds" && check_ok "CRD" "$c" || check_ng "CRD: $c" "있음" "없음" "CAPO 설치 실패"
done
cm="$(kc -n cert-manager get deploy cert-manager -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://')"
[[ "$cm" == "$CERT_MANAGER_OBSERVED" ]] && check_ok "cert-manager 버전" "$cm" || check_warn "cert-manager 버전 ${cm:-불명}" "수동 구축 관찰값 $CERT_MANAGER_OBSERVED 와 다름(clusterctl 이 선택하므로 고정되지 않음)"

# 관리 클러스터 안에서의 외부 접근
for u in $KIND_REGISTRIES; do
  c="$(docker exec "${KIND_CLUSTER}-control-plane" curl -s -o /dev/null -m 10 -w '%{http_code}' "$u" 2>/dev/null || true)"
  [[ "$c" == "401" ]] && check_ok "관리 클러스터 → ${u#https://}" "HTTP $c" || check_ng "관리 클러스터 → ${u#https://}" "HTTP 401" "HTTP ${c:-없음}" "kind 대역 NAT 규칙, 호스트 방화벽 확인"
done
c="$(docker exec "${KIND_CLUSTER}-control-plane" curl -s -o /dev/null -m 10 -w '%{http_code}' "http://${KOLLA_VIP}:5000/v3" 2>/dev/null || true)"
[[ "$c" == "200" ]] && check_ok "관리 클러스터 → OpenStack API" "HTTP $c" || check_ng "관리 클러스터 → OpenStack API" "HTTP 200" "HTTP ${c:-없음}" "INPUT 규칙(kolla0 의 VIP 허용), 호스트 방화벽 확인"

report_summary || die "점검 실패. 위 [FAIL] 항목을 해결한 뒤 다시 실행하세요." "$EXIT_FAIL"
log_done "3단계 사후 점검 통과"
