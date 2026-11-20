#!/usr/bin/env bash
# stage4/apply.sh — 4단계: CAPO 로 OpenStack 위에 Kubernetes 클러스터(컨트롤플레인 1 + 워커 2)를 만든다.
#
#   --dry-run  변경 없이 실행 계획만 출력 (이미 구축된 서버에서는 전부 SKIP 이어야 한다)
#   --yes      확인 질문 없이 진행
#
# 순서: orc -> capo_ready -> secret -> manifest -> cluster_create -> cluster_wait -> kubeconfig
#
# 수동 구축에서 얻은 규칙
#  - CAPO v0.15.1 은 ORC CRD 가 없으면 시작 약 2분 뒤 CrashLoop 이 되고 webhook 도 응답하지 않는다. ORC 설치 뒤 CAPO 를 재시작한다.
#    clusterctl init 직후 잠깐 Running 으로 보여도 안심하지 않는다. 재시작 직후 검증은 실패할 수 있어 재시도한다.
#  - kind -> 외부망(API 서버 Floating IP 6443) 경로는 호스트 방화벽 FORWARD 규칙이 있어야 한다(3단계 nat 단계가 영속화). 없으면 INITIALIZED 가 비고 워커가 Pending 에 머문다.
#  - 인증 Secret 은 clouds.yaml 전체를 담는다. 값은 출력하지 않고 해시로만 비교한다.
#  - 주문서는 완성본 템플릿에서 값만 채운다(ext-net ID 는 환경마다 달라 조회). 이미 있는 주문서는 덮어쓰지 않는다.
#  - 이 단계 끝에서 노드는 NotReady 가 정상이다(CNI 는 5단계).
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage4 apply

HERE="$KIT_ROOT/stage4"
KUBECTL="$BIN_DIR/kubectl"; CLUSTERCTL="$BIN_DIR/clusterctl"
OSC="$KOLLA_VENV/bin/openstack"
CLOUDS_YAML="$KOLLA_CONFIG_DIR/clouds.yaml"

kit_diagnose() {
  local t; t="$(tail -n 400 "$1" 2>/dev/null || true)"
  grep -qE "connection refused.*webhook|failed calling webhook" <<<"$t" \
    && hint "CAPO webhook 응답 없음" "ORC 설치 여부와 CAPO 재시작 후 1~2분 경과 여부 확인: kubectl --context $KUBE_CONTEXT -n capo-system get pods"
  grep -q 'no matches for kind "Image" in version "openstack.k-orc.cloud' <<<"$t" \
    && hint "ORC CRD 없음" "ORC ${ORC_VERSION} 설치 후 capo-controller-manager 재시작"
  return 0
}

kc() { "$KUBECTL" --context "$KUBE_CONTEXT" "$@"; }
os() { OS_CLIENT_CONFIG_FILE="$CLOUDS_YAML" timeout 60 "$OSC" --os-cloud "$KOLLA_CLOUD" "$@"; }
mgmt_up() { kc get nodes >/dev/null 2>&1; }

render_manifest() {
  local ext; ext="$(os network show "$EXT_NET_NAME" -c id -f value 2>/dev/null || true)"
  [[ -n "$ext" ]] || { echo "ext-net ID 를 조회하지 못했습니다" >&2; return 1; }
  sed -e "s|@CLUSTER@|${CLUSTER_NAME}|g" -e "s|@POD_CIDR@|${POD_CIDR}|g" -e "s|@WORKERS@|${WORKER_REPLICAS}|g" \
      -e "s|@CP_REPLICAS@|${CP_REPLICAS}|g" -e "s|@AZ@|${NODE_AZ}|g" -e "s|@K8S_SEMVER@|${K8S_SEMVER}|g" \
      -e "s|@EXT_NET_ID@|${ext}|g" -e "s|@CLOUD_NAME@|${KOLLA_CLOUD}|g" -e "s|@SECRET_NAME@|${CLOUD_SECRET_NAME}|g" \
      -e "s|@NET@|${K8S_NET_NAME}|g" -e "s|@SUBNET@|k8s-subnet|g" -e "s|@FLAVOR@|${NODE_FLAVOR}|g" \
      -e "s|@IMAGE@|${NODE_IMAGE_NAME}|g" -e "s|@KEYPAIR@|${NODE_KEYPAIR}|g" "$HERE/k8s-lab.yaml.tpl"
}

capo_running() { kc -n capo-system get pods --no-headers 2>/dev/null | awk '{if ($2=="1/1" && $3=="Running") ok=1} END{exit ok?0:1}'; }
orc_ready() {
  kc get crd images.openstack.k-orc.cloud >/dev/null 2>&1 || return 1
  kc -n orc-system get deploy --no-headers 2>/dev/null | awk '{split($2,a,"/"); if (a[1]>=1 && a[1]==a[2]) ok=1} END{exit ok?0:1}'
}
cluster_exists() { kc -n default get cluster "$CLUSTER_NAME" >/dev/null 2>&1; }
kcp_initialized() {
  kc -n default get kubeadmcontrolplane "${CLUSTER_NAME}-control-plane" -o json 2>/dev/null | python3 -c '
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
print("true" if f(d.get("status", {})) else "false")'
}
machines_ok() {   # 기대 대수가 모두 Running 이고 노드 이름이 채워졌는지
  local want=$((CP_REPLICAS + WORKER_REPLICAS)) n
  n="$(kc -n default get machines -l "cluster.x-k8s.io/cluster-name=${CLUSTER_NAME}" -o jsonpath='{range .items[*]}{.status.phase}{" "}{.status.nodeRef.name}{"\n"}{end}' 2>/dev/null | awk '$1=="Running" && $2!="" {c++} END{print c+0}')"
  [[ "$n" -eq "$want" ]]
}
secret_hash() { kc -n default get secret "$CLOUD_SECRET_NAME" -o jsonpath='{.data.clouds\.yaml}' 2>/dev/null | base64 -d 2>/dev/null | sha256sum | cut -d' ' -f1 || true; }
file_hash()   { sha256sum "$CLOUDS_YAML" 2>/dev/null | cut -d' ' -f1 || true; }
kubeconfig_ok() { [[ -s "$CLUSTER_KUBECONFIG" && "$(stat -c '%a' "$CLUSTER_KUBECONFIG")" == "600" ]] && timeout 30 "$KUBECTL" --kubeconfig "$CLUSTER_KUBECONFIG" get nodes >/dev/null 2>&1; }

STEPS=(orc capo_ready secret manifest cluster_create cluster_wait kubeconfig)
declare -A TITLE=(
  [orc]="ORC ${ORC_VERSION} (CAPO 가 요구)"
  [capo_ready]="CAPO 컨트롤러 Running"
  [secret]="OpenStack 인증 Secret ${CLOUD_SECRET_NAME}"
  [manifest]="클러스터 주문서 ${CLUSTER_MANIFEST}"
  [cluster_create]="클러스터 ${CLUSTER_NAME} 생성(kubectl apply)"
  [cluster_wait]="컨트롤플레인 INITIALIZED, 머신 $((CP_REPLICAS + WORKER_REPLICAS))대 Running"
  [kubeconfig]="워크로드 클러스터 kubeconfig ${CLUSTER_KUBECONFIG}"
)
REASON=""; PLAN=()

need_orc() {
  if ! mgmt_up; then REASON="관리 클러스터($KUBE_CONTEXT)에 접속할 수 없음 — 3단계 필요"; return 0; fi
  if orc_ready; then REASON="ORC CRD 있음, orc-system Deployment Available"; return 1; fi
  REASON="ORC CRD 없음 또는 Deployment 미준비"; return 0
}
do_orc() {
  mgmt_up || die "관리 클러스터($KUBE_CONTEXT)에 접속할 수 없습니다. 3단계를 먼저 실행하세요." "$EXIT_FAIL"
  run_step "ORC 설치(server-side apply)" "$KUBECTL" --context "$KUBE_CONTEXT" apply --server-side -f "$ORC_URL"
  run_step "ORC Deployment Available 대기" "$KUBECTL" --context "$KUBE_CONTEXT" wait --for=condition=Available deployment --all -n orc-system --timeout=180s
}

need_capo_ready() {
  if ! mgmt_up; then REASON="관리 클러스터 없음"; return 0; fi
  if [[ " ${PLAN[*]:-} " == *" orc "* ]]; then REASON="ORC 를 새로 설치하므로 CAPO 를 재시작"; return 0; fi
  if capo_running; then REASON="capo-controller-manager 1/1 Running"; return 1; fi
  REASON="capo-controller-manager 가 Running 이 아님"; return 0
}
do_capo_ready() {
  run_step "CAPO 재시작" "$KUBECTL" --context "$KUBE_CONTEXT" rollout restart deployment/capo-controller-manager -n capo-system
  run_step "CAPO 롤아웃 대기" "$KUBECTL" --context "$KUBE_CONTEXT" rollout status deployment/capo-controller-manager -n capo-system --timeout=180s
  log_info "재시작 직후에는 webhook 이 아직 응답하지 않을 수 있어 60초 기다립니다."
  sleep 60
  capo_running || die "CAPO 가 Running 이 아닙니다. 'kubectl --context $KUBE_CONTEXT -n capo-system logs deploy/capo-controller-manager --tail=40' 확인" "$EXIT_FAIL"
}

need_secret() {
  if ! mgmt_up; then REASON="관리 클러스터 없음"; return 0; fi
  [[ -r "$CLOUDS_YAML" ]] || { REASON="$CLOUDS_YAML 을 읽을 수 없음(1단계 필요)"; return 0; }
  local sh; sh="$(secret_hash)"
  if [[ -z "$sh" ]]; then REASON="Secret 없음"; return 0; fi
  if [[ "$sh" != "$(file_hash)" ]]; then REASON="Secret 내용이 $CLOUDS_YAML 과 다름(해시만 비교, 값은 출력하지 않음)"; return 0; fi
  if [[ "$(kc -n default get secret "$CLOUD_SECRET_NAME" -o jsonpath='{.metadata.labels.clusterctl\.cluster\.x-k8s\.io/move}' 2>/dev/null)" != "true" ]]; then REASON="move 라벨 없음"; return 0; fi
  REASON="Secret 이 있고 내용과 라벨이 일치"; return 1
}
make_secret() {
  [[ -r "$CLOUDS_YAML" ]] || { echo "$CLOUDS_YAML 을 읽을 수 없습니다" >&2; return 1; }
  "$KUBECTL" --context "$KUBE_CONTEXT" -n default create secret generic "$CLOUD_SECRET_NAME" --from-file=clouds.yaml="$CLOUDS_YAML" --dry-run=client -o yaml \
    | "$KUBECTL" --context "$KUBE_CONTEXT" apply -f - >/dev/null
  "$KUBECTL" --context "$KUBE_CONTEXT" -n default label secret "$CLOUD_SECRET_NAME" clusterctl.cluster.x-k8s.io/move=true --overwrite
}
do_secret() { run_step "인증 Secret 생성·갱신(값은 출력하지 않음)" make_secret; }

need_manifest() {
  local tmp; tmp="$(mktemp)"
  if ! render_manifest >"$tmp" 2>/dev/null; then rm -f "$tmp"; REASON="주문서를 렌더할 수 없음(ext-net 조회 실패). 2단계 필요"; return 0; fi
  if [[ ! -f "$CLUSTER_MANIFEST" ]]; then rm -f "$tmp"; REASON="$CLUSTER_MANIFEST 없음"; return 0; fi
  if diff -q "$tmp" "$CLUSTER_MANIFEST" >/dev/null 2>&1; then rm -f "$tmp"; REASON="$CLUSTER_MANIFEST 가 렌더 결과와 같음"; return 1; fi
  rm -f "$tmp"
  if [[ "$FORCE_OVERWRITE_MANIFEST" == "1" ]]; then REASON="주문서가 렌더 결과와 다름(교체 예정)"; return 0; fi
  check_warn "주문서가 렌더 결과와 다름" "덮어쓰지 않는다. 교체하려면 FORCE_OVERWRITE_MANIFEST=1 (이미 만든 클러스터에는 영향 없음)"
  REASON="주문서가 렌더 결과와 다르지만 덮어쓰지 않음"; return 1
}
do_manifest() {
  mkdir -p "$CAPI_DIR"
  [[ -f "$CLUSTER_MANIFEST" ]] && run_step "주문서 백업" cp -n "$CLUSTER_MANIFEST" "${CLUSTER_MANIFEST}.bak-kit"
  render_manifest >"$CLUSTER_MANIFEST.tmp" || die "주문서를 렌더하지 못했습니다(ext-net 조회 실패)." "$EXIT_FAIL"
  mv "$CLUSTER_MANIFEST.tmp" "$CLUSTER_MANIFEST"
  log_info "작성: $CLUSTER_MANIFEST"
}

need_cluster_create() {
  if ! mgmt_up; then REASON="관리 클러스터 없음"; return 0; fi
  if cluster_exists; then REASON="클러스터 $CLUSTER_NAME 가 이미 있음"; return 1; fi
  REASON="클러스터 $CLUSTER_NAME 없음"; return 0
}
do_cluster_create() {
  # 서버 쪽 검증. CAPO 재시작 직후에는 webhook 이 실패할 수 있어 재시도한다.
  local i ok=0
  for i in 1 2 3 4 5 6; do
    if kc apply --dry-run=server -f "$CLUSTER_MANIFEST" >>"$KIT_LOG_FILE" 2>&1; then ok=1; break; fi
    log_warn "서버 검증 실패(시도 $i/6). 30초 뒤 다시 시도합니다(CAPO webhook 준비 대기)."
    sleep 30
  done
  [[ "$ok" == "1" ]] || { kit_diagnose "$KIT_LOG_FILE"; die "주문서 서버 검증이 계속 실패합니다. 로그: $KIT_LOG_FILE" "$EXIT_FAIL"; }
  log_done "주문서 서버 검증 통과"
  run_step "kubectl apply(클러스터 생성)" "$KUBECTL" --context "$KUBE_CONTEXT" apply -f "$CLUSTER_MANIFEST"
}

need_cluster_wait() {
  if ! mgmt_up || ! cluster_exists; then REASON="클러스터 없음"; return 0; fi
  if [[ "$(kcp_initialized)" == "true" ]] && machines_ok; then REASON="INITIALIZED=true, 머신 $((CP_REPLICAS + WORKER_REPLICAS))대 Running"; return 1; fi
  REASON="INITIALIZED=$(kcp_initialized), 머신 준비 미완료"; return 0
}
do_cluster_wait() {
  local waited=0
  log_info "클러스터가 준비될 때까지 최대 ${CLUSTER_WAIT_SECS}초 기다립니다(수동 관찰: 약 3~6분)."
  while [[ "$waited" -lt "$CLUSTER_WAIT_SECS" ]]; do
    if [[ "$(kcp_initialized)" == "true" ]] && machines_ok; then log_done "클러스터 준비 완료 (${waited}초)"; return 0; fi
    if (( waited % 60 == 0 )); then log_info "대기 중 ${waited}초: INITIALIZED=$(kcp_initialized)"; fi
    sleep 10; waited=$((waited + 10))
  done
  hint "클러스터가 ${CLUSTER_WAIT_SECS}초 안에 준비되지 않음" "호스트 방화벽 FORWARD 규칙(3단계 nat), CAPO 로그, 'kubectl --context $KUBE_CONTEXT get kubeadmcontrolplane,machine -A', 'openstack server list' 확인"
  die "클러스터 준비 시간 초과" "$EXIT_FAIL"
}

need_kubeconfig() {
  if kubeconfig_ok; then REASON="kubeconfig 있음(권한 600), 클러스터 접속 성공"; return 1; fi
  REASON="kubeconfig 없음, 권한이 600 이 아님, 또는 접속 실패"; return 0
}
do_kubeconfig() {
  log_step "워크로드 클러스터 kubeconfig 추출(내용은 로그에 남기지 않음)"
  mkdir -p "$CAPI_DIR"
  ( umask 077; "$CLUSTERCTL" get kubeconfig "$CLUSTER_NAME" --kubeconfig-context "$KUBE_CONTEXT" >"${CLUSTER_KUBECONFIG}.tmp" ) \
    || { rm -f "${CLUSTER_KUBECONFIG}.tmp"; die "kubeconfig 를 가져오지 못했습니다. 클러스터가 준비되었는지 확인하세요." "$EXIT_FAIL"; }
  [[ -s "${CLUSTER_KUBECONFIG}.tmp" ]] || { rm -f "${CLUSTER_KUBECONFIG}.tmp"; die "kubeconfig 가 비어 있습니다." "$EXIT_FAIL"; }
  mv "${CLUSTER_KUBECONFIG}.tmp" "$CLUSTER_KUBECONFIG"; chmod 600 "$CLUSTER_KUBECONFIG"
  kubeconfig_ok || die "kubeconfig 로 클러스터에 접속하지 못했습니다." "$EXIT_FAIL"
  log_done "kubeconfig 저장(권한 600): $CLUSTER_KUBECONFIG"
}

# ------------------------------------------------------------------ 계획 수립
log_info "4단계 계획을 세웁니다 (로그: $KIT_LOG_FILE)"
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
  impact="${#PLAN[@]}개 단계 실행:"
  [[ " ${PLAN[*]} " == *" orc "* ]]            && impact+=" 관리 클러스터에 ORC ${ORC_VERSION} 설치(GitHub 에서 매니페스트 내려받음);"
  [[ " ${PLAN[*]} " == *" cluster_create "* ]] && impact+=" OpenStack 에 VM $((CP_REPLICAS + WORKER_REPLICAS))대(각 flavor ${NODE_FLAVOR}), 포트, 보안 그룹 2개, Floating IP 1개 생성(약 12 vCPU, 24GiB, 180GB 사용);"
  confirm "$impact" "클러스터: 'kubectl --context $KUBE_CONTEXT delete cluster $CLUSTER_NAME' (CAPO 가 OpenStack 자원을 정리). Secret: 'kubectl --context $KUBE_CONTEXT -n default delete secret $CLOUD_SECRET_NAME'. ORC: 'kubectl --context $KUBE_CONTEXT delete -f $ORC_URL'"
fi

for id in "${PLAN[@]}"; do
  log_step "== ${TITLE[$id]}"
  "do_$id"
done

report_summary || true
log_done "4단계 실행 완료 (노드는 NotReady 가 정상입니다. CNI 는 5단계)"
