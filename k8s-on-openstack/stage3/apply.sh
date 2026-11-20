#!/usr/bin/env bash
# stage3/apply.sh — 3단계: kind 관리 클러스터를 만들고 Cluster API(CAPO 포함)를 설치한다.
#
#   --dry-run  변경 없이 실행 계획만 출력 (이미 구축된 서버에서는 전부 SKIP 이어야 한다)
#   --yes      호스트 변경 확인 질문 없이 진행
#
# 순서: docker_access -> nat -> kind_cluster -> clusterctl_init -> wait_ready
#
# 수동 구축에서 얻은 규칙
#  - Docker 는 새 로그인 세션에서만 docker 그룹이 적용된다. sudo 없이 docker 가 안 되면 종료 코드 2 로 재접속을 안내한다.
#  - Kolla 가 daemon.json 에 iptables:false 를 넣어 Docker 가 NAT 를 만들지 않는다. kind 대역에서 호스트 NIC 로 나가는 MASQUERADE 를
#    kind 생성 전에 넣지 않으면 clusterctl init 이 10분 뒤 context deadline exceeded 로 실패한다. 호스트 네트워크 스크립트에 영속화한다.
#  - kind 노드 이미지는 digest 까지 고정한다. 모든 kubectl/clusterctl 은 --context kind-mgmt 를 명시한다.
#  - clusterctl init 출력을 파이프로 줄이지 않는다.
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage3 apply

KUBECTL="$BIN_DIR/kubectl"; KIND="$BIN_DIR/kind"; CLUSTERCTL="$BIN_DIR/clusterctl"
KIT_TMP=""
trap '[[ -n "$KIT_TMP" ]] && rm -rf "$KIT_TMP"' EXIT

kit_diagnose() {
  local t; t="$(tail -n 400 "$1" 2>/dev/null || true)"
  grep -q "context deadline exceeded" <<<"$t" \
    && hint "clusterctl init 시간 초과" "kind 대역 NAT(MASQUERADE) 부재가 가장 흔한 원인. 'sudo iptables -t nat -S POSTROUTING' 에 ${KIND_NET_CIDR} 규칙이 있는지 확인 후 'kubectl --context ${KUBE_CONTEXT} -n cert-manager delete pods --all'"
  grep -qE "permission denied.*docker.sock|Cannot connect to the Docker daemon" <<<"$t" \
    && hint "docker 접근 불가" "docker 그룹은 새 로그인 세션에서만 적용된다. 재접속(tmux 서버 재시작 포함)"
  grep -q "ImagePullBackOff" <<<"$t" && hint "이미지 내려받기 실패" "관리 클러스터 컨테이너에서 레지스트리 4곳이 401 로 응답하는지 확인"
  return 0
}

kc() { "$KUBECTL" --context "$KUBE_CONTEXT" "$@"; }
docker_usable() { docker ps >/dev/null 2>&1; }
kind_exists() { docker_usable && "$KIND" get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; }
kind_subnet() { docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/' | head -n1 || true; }
node_ready() { kc get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -qx Ready; }
providers_ok() {
  local out; out="$(kc get providers.clusterctl.cluster.x-k8s.io -A --no-headers 2>/dev/null || true)"
  grep -qE "cluster-api .*v${CLUSTERCTL_VERSION}" <<<"$out" && grep -qE "bootstrap-kubeadm .*v${CLUSTERCTL_VERSION}" <<<"$out" \
    && grep -qE "control-plane-kubeadm .*v${CLUSTERCTL_VERSION}" <<<"$out" && grep -qE "infrastructure-openstack .*${CAPO_VERSION}" <<<"$out"
}
pods_not_ready() {   # 준비되지 않은 파드 목록(없으면 빈 문자열)
  kc get pods -A --no-headers 2>/dev/null | awk '{split($3,a,"/"); if ($4!="Running" && $4!="Completed") print $1"/"$2" "$4; else if ($4=="Running" && a[1]!=a[2]) print $1"/"$2" not-ready"}'
}
nat_script_has() { sudo -n grep -qF -- "$1" "$HOST_NET_SCRIPT" 2>/dev/null; }
NAT_LINE="-s ${KIND_NET_CIDR} -o ${HOST_NIC} -j MASQUERADE"
FWD_LINE="-s ${KIND_NET_CIDR} -d ${EXT_NET_CIDR} -o ${EXT_HOST_IF} -j ACCEPT"

STEPS=(docker_access nat kind_cluster clusterctl_init wait_ready)
declare -A TITLE=(
  [docker_access]="docker 를 sudo 없이 사용"
  [nat]="kind 대역(${KIND_NET_CIDR}) 외부 NAT 와 FORWARD 규칙 영속화"
  [kind_cluster]="kind 관리 클러스터 ${KIND_CLUSTER} (노드 ${MGMT_NODE_VERSION})"
  [clusterctl_init]="clusterctl init (Cluster API v${CLUSTERCTL_VERSION}, CAPO ${CAPO_VERSION})"
  [wait_ready]="컨트롤러 파드 Running 대기"
)
REASON=""

need_docker_access() {
  if docker_usable; then REASON="docker ps 성공"; return 1; fi
  REASON="docker ps 실패(그룹 미적용 또는 서비스 중지)"; return 0
}
do_docker_access() {
  if user_in_group_db docker; then
    report_summary || true
    log_warn "docker 그룹은 있지만 현재 세션에 적용되지 않았습니다. 이것은 실패가 아니라 설계된 중단입니다."
    log_info "새로 로그인하고(tmux 서버도 종료 후 새로 시작) 같은 명령을 다시 실행하세요."
    exit "$EXIT_RELOGIN"
  fi
  die "docker 를 쓸 수 없습니다. 1단계(make stage-1)에서 docker 그룹 추가와 설치가 끝났는지 확인하세요." "$EXIT_FAIL"
}

need_nat() {
  local miss=()
  sudo -n iptables -t nat -C POSTROUTING $NAT_LINE 2>/dev/null || miss+=("NAT 규칙(실시간) 없음")
  sudo -n iptables -C FORWARD $FWD_LINE 2>/dev/null || miss+=("FORWARD 규칙(실시간) 없음")
  nat_script_has "$NAT_LINE" || miss+=("호스트 네트워크 스크립트에 NAT 줄 없음")
  nat_script_has "$FWD_LINE" || miss+=("호스트 네트워크 스크립트에 FORWARD 줄 없음")
  if [[ "${#miss[@]}" -gt 0 ]]; then REASON="${miss[*]}"; return 0; fi
  REASON="실시간 규칙 2개와 스크립트 줄 2개 모두 있음"; return 1
}
do_nat() {
  [[ -f "$HOST_NET_SCRIPT" ]] || die "$HOST_NET_SCRIPT 가 없습니다. 1단계(host_net)를 먼저 실행하세요." "$EXIT_FAIL"
  KIT_TMP="$(mktemp -d)"
  sudo -n cat "$HOST_NET_SCRIPT" | tee "$KIT_TMP/new.sh" >/dev/null
  if ! nat_script_has "$NAT_LINE"; then
    printf '%s\n' "# kind (Docker) ${KIND_NET_CIDR} outbound NAT; daemon.json has iptables:false so Docker adds none" \
      "\$IPT -t nat -C POSTROUTING ${NAT_LINE} 2>/dev/null || \$IPT -t nat -A POSTROUTING ${NAT_LINE}" >>"$KIT_TMP/new.sh"
  fi
  if ! nat_script_has "$FWD_LINE"; then
    printf '%s\n' "# allow kind containers (${KIND_NET_CIDR}) to reach external-net/VMs; BM-Firewall-INPUT in FORWARD rejects unlisted ports" \
      "\$IPT -C FORWARD ${FWD_LINE} 2>/dev/null || \$IPT -I FORWARD 1 ${FWD_LINE}" >>"$KIT_TMP/new.sh"
  fi
  bash -n "$KIT_TMP/new.sh" || die "수정한 호스트 네트워크 스크립트에 문법 오류가 있습니다. 원본은 그대로입니다." "$EXIT_FAIL"
  run_step "호스트 네트워크 스크립트 백업" sudo cp -pn "$HOST_NET_SCRIPT" "${HOST_NET_SCRIPT}.bak-before-kind"
  run_step "호스트 네트워크 스크립트 갱신" sudo install -m 0755 "$KIT_TMP/new.sh" "$HOST_NET_SCRIPT"
  run_step "호스트 네트워크 적용(멱등 스크립트 재실행)" sudo systemctl restart kolla-host-net.service
  need_nat && die "규칙을 적용했지만 아직 부족합니다: $REASON" "$EXIT_FAIL"
}

need_kind_cluster() {
  if ! docker_usable; then REASON="docker 사용 불가 — 앞 단계 필요"; return 0; fi
  if kind_exists; then REASON="클러스터 $KIND_CLUSTER 있음(Ready 여부는 wait_ready 에서 확인)"; return 1; fi
  REASON="클러스터 $KIND_CLUSTER 없음"; return 0
}
do_kind_cluster() {
  mkdir -p "$HOME/.kube"
  [[ -f "$HOME/.kube/config" ]] && run_step "kubeconfig 백업" cp -n "$HOME/.kube/config" "$HOME/.kube/config.bak-kit"
  run_step "kind create cluster" "$KIND" create cluster --name "$KIND_CLUSTER" --image "$KIND_NODE_IMAGE"
  local sub; sub="$(kind_subnet)"
  if [[ "$sub" != "$KIND_NET_CIDR" ]]; then
    die "kind 네트워크 대역이 ${sub:-불명} 입니다(기대 ${KIND_NET_CIDR}). NAT/FORWARD 규칙이 다른 대역에 걸려 있습니다. versions.env 의 KIND_NET_CIDR 을 ${sub:-실제 값} 으로 바꾸고 이 단계를 다시 실행하세요(클러스터는 그대로 둡니다)." "$EXIT_FAIL"
  fi
  local n=0
  until node_ready; do n=$((n + 1)); [[ "$n" -gt 30 ]] && die "관리 클러스터 노드가 Ready 가 되지 않았습니다." "$EXIT_FAIL"; sleep 5; done
}

need_clusterctl_init() {
  if ! kind_exists; then REASON="관리 클러스터 없음 — 앞 단계 필요"; return 0; fi
  if providers_ok; then REASON="provider 4개(cluster-api, kubeadm 2개, openstack)가 지정 버전으로 설치됨"; return 1; fi
  REASON="provider 가 없거나 버전이 다름"; return 0
}
do_clusterctl_init() {
  # 레지스트리에 못 나가면 init 이 10분을 기다리다 실패한다. 먼저 확인한다.
  local u code bad=()
  for u in $KIND_REGISTRIES; do
    code="$(docker exec "${KIND_CLUSTER}-control-plane" curl -s -o /dev/null -m 10 -w '%{http_code}' "$u" 2>/dev/null || true)"
    [[ "$code" == "401" || "$code" == "200" ]] || bad+=("$u(HTTP ${code:-없음})")
  done
  [[ "${#bad[@]}" -eq 0 ]] || die "관리 클러스터 안에서 레지스트리에 닿지 않습니다: ${bad[*]}. NAT 규칙(${NAT_LINE})과 'sudo iptables -t nat -S POSTROUTING' 확인" "$EXIT_FAIL"
  run_step "clusterctl init" timeout 1200 "$CLUSTERCTL" init --kubeconfig-context "$KUBE_CONTEXT" \
    --core "cluster-api:v${CLUSTERCTL_VERSION}" --bootstrap "kubeadm:v${CLUSTERCTL_VERSION}" \
    --control-plane "kubeadm:v${CLUSTERCTL_VERSION}" --infrastructure "openstack:${CAPO_VERSION}"
}

need_wait_ready() {
  if ! kind_exists; then REASON="관리 클러스터 없음"; return 0; fi
  local bad; bad="$(pods_not_ready | tr '\n' ' ')"
  if [[ -z "${bad// }" ]] && node_ready; then REASON="노드 Ready, 모든 파드 Running"; return 1; fi
  REASON="준비 안 됨: ${bad:-노드 NotReady}"; return 0
}
do_wait_ready() {
  local waited=0 bad=""
  while [[ "$waited" -lt "$WAIT_PODS_SECS" ]]; do
    bad="$(pods_not_ready | tr '\n' ' ')"
    if [[ -z "${bad// }" ]] && node_ready && providers_ok; then log_done "모든 파드 Running (${waited}초)"; return 0; fi
    sleep 5; waited=$((waited + 5))
  done
  die "${WAIT_PODS_SECS}초 안에 준비되지 않았습니다: ${bad:-노드/provider}. 'kubectl --context $KUBE_CONTEXT get pods -A' 확인" "$EXIT_FAIL"
}

# ------------------------------------------------------------------ 계획 수립
log_info "3단계 계획을 세웁니다 (로그: $KIT_LOG_FILE)"
PLAN=()
for id in "${STEPS[@]}"; do
  REASON=""
  if "need_$id"; then PLAN+=("$id"); log_info "[실행 예정] ${TITLE[$id]} — $REASON"
  else log_skip "${TITLE[$id]} — $REASON"; fi
done

if [[ "${#PLAN[@]}" -eq 0 ]]; then
  log_done "할 일이 없습니다. 모든 항목이 이미 충족되어 있습니다."
elif [[ "$KIT_DRY_RUN" == "1" ]]; then
  log_info "(dry-run) 위 [실행 예정] ${#PLAN[@]}개 단계만 실제 실행 시 변경됩니다. 아무것도 바꾸지 않고 종료합니다."
  report_summary || true
  exit "$EXIT_OK"
else
  sudo_nopass || die "sudo 를 비밀번호 없이 쓸 수 없습니다." "$EXIT_FAIL"
  impact="${#PLAN[@]}개 단계 실행:"
  [[ " ${PLAN[*]} " == *" nat "* ]]            && impact+=" 호스트 방화벽에 kind 대역 NAT·FORWARD 규칙 추가, ${HOST_NET_SCRIPT} 에 줄 추가(원본 백업);"
  [[ " ${PLAN[*]} " == *" kind_cluster "* ]]   && impact+=" Docker 컨테이너로 관리 클러스터 생성, ~/.kube/config 에 컨텍스트 추가;"
  [[ " ${PLAN[*]} " == *" clusterctl_init "* ]] && impact+=" 관리 클러스터에 Cluster API, CAPO, cert-manager 설치;"
  confirm "$impact" "관리 클러스터: '$KIND delete cluster --name $KIND_CLUSTER'. 방화벽: '${HOST_NET_SCRIPT}.bak-before-kind' 로 스크립트 복원 후 'sudo systemctl restart kolla-host-net.service' (이미 적용된 규칙은 iptables -D 로 삭제)"
fi

for id in "${PLAN[@]}"; do
  log_step "== ${TITLE[$id]}"
  "do_$id"
done

report_summary || true
log_done "3단계 실행 완료"
