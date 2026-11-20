#!/usr/bin/env bash
# stage5/apply.sh — 5단계: 워크로드 클러스터에 OCCM 과 Calico 를 설치한다. (검증 b~e 는 stage5/verify-bcde.sh)
#
#   --dry-run  변경 없이 실행 계획만 출력 (이미 구축된 서버에서는 전부 SKIP 이어야 한다)
#   --yes      확인 질문 없이 진행
#
# 순서: files -> typha_sg -> occm_secret -> occm_deploy -> calico -> wait_ready
#
# 수동 구축에서 얻은 규칙
#  - OpenStack 에 Octavia 가 없으면 OCCM 설정에서 [LoadBalancer] enabled=false 가 필수다. 없으면 OCCM 이 fatal 로 종료하고,
#    노드의 uninitialized 테인트가 풀리지 않아 Calico 파드 일부가 Pending 에 머문다. 증상이 Calico 쪽에 보이므로 OCCM 부터 의심한다.
#  - CAPO 기본 보안 그룹에는 Calico Typha(5473/tcp)가 없다. 워커 SG 에 컨트롤플레인 SG, 워커 SG 출발지 규칙 2개를 더한다.
#  - Calico CRD 는 3.5MB 라 kubectl apply 가 아니라 create 를 쓴다(annotation 크기 제한).
#  - OCCM 매니페스트는 master 가 아니라 태그(OCCM_VERSION)로 고정한다. 시크릿(cloud.conf)은 파일로 남기지 않고 값은 출력하지 않는다.
#  - OCCM 이 동작하기 전에는 kubectl logs/exec 가 실패한다. 그래서 완료 판정은 get/describe 로만 한다.
#  - 순서 변경(수동은 Calico -> OCCM): OCCM 을 먼저 설치해 Calico 파드가 Pending 에 걸리는 구간을 없앤다. 이 순서는 시험하지 않았다.
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage5 apply

KUBECTL="$BIN_DIR/kubectl"; OSC="$KOLLA_VENV/bin/openstack"; CFG="$KOLLA_CONFIG_DIR/clouds.yaml"
KIT_TMP=""
trap '[[ -n "$KIT_TMP" ]] && rm -rf "$KIT_TMP"' EXIT
wk() { "$KUBECTL" --kubeconfig "$CLUSTER_KUBECONFIG" "$@"; }
os() { OS_CLIENT_CONFIG_FILE="$CFG" timeout 60 "$OSC" --os-cloud "$KOLLA_CLOUD" "$@"; }
wk_up() { [[ -s "$CLUSTER_KUBECONFIG" ]] && timeout 30 "$KUBECTL" --kubeconfig "$CLUSTER_KUBECONFIG" get nodes >/dev/null 2>&1; }

kit_diagnose() {
  local t; t="$(tail -n 400 "$1" 2>/dev/null || true)"
  grep -q "No suitable endpoint could be found in the service catalog" <<<"$t" \
    && hint "OCCM 이 LoadBalancer 클라이언트를 만들지 못함" "cloud.conf 에 [LoadBalancer] enabled=false 가 있어야 한다(Octavia 없음)"
  grep -qE "connection refused.*tigera|tigerastatus" <<<"$t" \
    && hint "Calico 웹훅 응답 없음" "OCCM 이 Running 인지 먼저 확인(uninitialized 테인트가 풀려야 Calico 파드가 뜬다)"
  return 0
}

CALICO_FILES=(v3_projectcalico_org.yaml tigera-operator.yaml custom-resources.yaml)
OCCM_FILES=(cloud-controller-manager-roles.yaml cloud-controller-manager-role-bindings.yaml openstack-cloud-controller-manager-ds.yaml)
CR_IPIP="$CALICO_DIR/custom-resources-ipip.yaml"
CP_SG="k8s-cluster-default-${CLUSTER_NAME}-secgroup-controlplane"
WK_SG="k8s-cluster-default-${CLUSTER_NAME}-secgroup-worker"

fetch_file() {   # <url> <dest> [sha256]
  local url="$1" dest="$2" want="${3:-}" got
  curl -fsSL --retry 3 --retry-delay 2 -o "$dest.tmp" "$url" || { rm -f "$dest.tmp"; return 1; }
  [[ -s "$dest.tmp" ]] || { rm -f "$dest.tmp"; echo "빈 파일: $url" >&2; return 1; }
  got="$(sha256sum "$dest.tmp" | cut -d' ' -f1)"
  echo "sha256 $(basename "$dest"): $got"
  if [[ -n "$want" && "$got" != "$want" ]]; then rm -f "$dest.tmp"; echo "sha256 불일치(기대 $want)" >&2; return 1; fi
  mv "$dest.tmp" "$dest"
}
render_ipip() { sed "s/encapsulation: VXLANCrossSubnet/encapsulation: ${CALICO_ENCAP}/" "$CALICO_DIR/custom-resources.yaml"; }

sg_id() { os security group show "$1" -f value -c id 2>/dev/null || true; }
typha_rule_present() {   # <대상 SG 이름> <출발지 SG ID>
  os security group rule list "$1" --ingress --protocol tcp -f json 2>/dev/null | python3 -c '
import sys, json
want_port, rid = sys.argv[1], sys.argv[2]
try: rules = json.load(sys.stdin)
except Exception: raise SystemExit(1)
for r in rules:
    pr = str(r.get("Port Range") or "")
    if pr in (want_port, want_port + ":" + want_port) and (r.get("Remote Security Group") or "") == rid:
        raise SystemExit(0)
raise SystemExit(1)' "$TYPHA_PORT" "$2"
}

gen_cloud_conf() {   # 값은 stdout 으로만 나간다. 호출하는 쪽이 출력하지 않아야 한다.
  local blk; blk="$(awk -v c="  ${KOLLA_CLOUD}:" '$0==c{f=1;next} /^  [^ ]/{f=0} f' "$CFG")"
  get() { echo "$blk" | awk -v k="$1:" '$1==k{ $1=""; sub(/^ /,""); print; exit}'; }
  echo "[Global]"
  echo "auth-url=$(get auth_url)"
  echo "username=\"$(get username)\""
  echo "password=\"$(get password)\""
  echo "tenant-name=\"$(get project_name)\""
  echo "domain-name=\"$(get user_domain_name)\""
  echo "region=\"$(get region_name)\""
  echo ""
  echo "[LoadBalancer]"
  echo "enabled=false"
}
conf_hash()   { gen_cloud_conf | sha256sum | cut -d' ' -f1 || true; }
secret_hash() { wk -n kube-system get secret cloud-config -o jsonpath='{.data.cloud\.conf}' 2>/dev/null | base64 -d 2>/dev/null | sha256sum | cut -d' ' -f1 || true; }
occm_ready()  { [[ "$(wk -n kube-system get ds openstack-cloud-controller-manager -o jsonpath='{.status.numberReady}' 2>/dev/null || true)" =~ ^[1-9][0-9]*$ ]]; }
crd_present() { [[ "$(wk get crd --no-headers 2>/dev/null | grep -c 'projectcalico.org' || true)" -gt 0 ]]; }
operator_present() { wk -n tigera-operator get deploy tigera-operator >/dev/null 2>&1; }
installation_present() { wk get installation default >/dev/null 2>&1; }

problems() {   # 아직 준비되지 않은 항목 목록(비어 있으면 모두 준비됨)
  local out="" name ts nodes bad
  ts="$(wk get tigerastatus -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="Available")]}{.status}{end}{"\n"}{end}' 2>/dev/null || true)"
  for name in $CALICO_EXPECTED_STATUS; do grep -qx "$name True" <<<"$ts" || out+="tigerastatus/$name "; done
  nodes="$(wk get nodes --no-headers 2>/dev/null || true)"
  [[ -n "$nodes" ]] || out+="nodes "
  bad="$(awk '$2!="Ready"{print $1}' <<<"$nodes" | tr '\n' ' ')"; [[ -z "${bad// }" ]] || out+="NotReady:${bad}"
  bad="$(wk get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints[*].key' --no-headers 2>/dev/null | { grep -E 'network-unavailable|uninitialized|not-ready|unreachable' || true; } | awk '{print $1}' | tr '\n' ' ')"
  [[ -z "${bad// }" ]] || out+="taint:${bad}"
  bad="$(wk get pods -A --no-headers 2>/dev/null | awk '{split($3,a,"/"); if ($4=="Completed"||$4=="Succeeded") next; if ($4!="Running" || a[1]!=a[2]) print $1"/"$2}' | tr '\n' ' ')"
  [[ -z "${bad// }" ]] || out+="pods:${bad}"
  occm_ready || out+="occm "
  printf '%s' "$out"
}

STEPS=(files typha_sg occm_secret occm_deploy calico wait_ready)
declare -A TITLE=(
  [files]="매니페스트 내려받기(Calico ${CALICO_VERSION}, OCCM ${OCCM_VERSION})와 IPIP 설정 생성"
  [typha_sg]="워커 보안 그룹에 Calico Typha ${TYPHA_PORT}/tcp 규칙 2개"
  [occm_secret]="OCCM 설정 Secret kube-system/cloud-config (LoadBalancer 비활성)"
  [occm_deploy]="OCCM ${OCCM_VERSION} 배포"
  [calico]="Calico ${CALICO_VERSION} (CRD, tigera-operator, ${CALICO_ENCAP} custom-resources)"
  [wait_ready]="노드 Ready, Calico·OCCM 정상, 테인트 해제 대기"
)
REASON=""; PLAN=()

need_files() {
  local miss=() f
  for f in "${CALICO_FILES[@]}"; do [[ -s "$CALICO_DIR/$f" ]] || miss+=("$f"); done
  for f in "${OCCM_FILES[@]}"; do [[ -s "$OCCM_DIR/$f" ]] || miss+=("$f"); done
  if [[ -s "$CALICO_DIR/custom-resources.yaml" ]]; then
    if [[ ! -s "$CR_IPIP" ]] || ! diff -q <(render_ipip) "$CR_IPIP" >/dev/null 2>&1; then miss+=("custom-resources-ipip.yaml"); fi
  fi
  if [[ "${#miss[@]}" -gt 0 ]]; then REASON="없음 또는 다름: ${miss[*]}"; return 0; fi
  REASON="매니페스트 6개와 IPIP 파일이 있음"; return 1
}
do_files() {
  mkdir -p "$CALICO_DIR" "$OCCM_DIR"
  local f sha
  for f in "${CALICO_FILES[@]}"; do
    [[ -s "$CALICO_DIR/$f" ]] && continue
    case "$f" in v3_*) sha="$CALICO_CRD_SHA256";; tigera-*) sha="$CALICO_OPERATOR_SHA256";; *) sha="$CALICO_CR_SHA256";; esac
    run_step "내려받기: calico/$f" fetch_file "$CALICO_BASE_URL/$f" "$CALICO_DIR/$f" "$sha"
  done
  for f in "${OCCM_FILES[@]}"; do
    [[ -s "$OCCM_DIR/$f" ]] && continue
    run_step "내려받기: occm/$f" fetch_file "$OCCM_BASE_URL/$f" "$OCCM_DIR/$f"
  done
  [[ -f "$CR_IPIP" ]] && cp -n "$CR_IPIP" "${CR_IPIP}.bak-kit"
  render_ipip >"$CR_IPIP"
  [[ "$(diff "$CALICO_DIR/custom-resources.yaml" "$CR_IPIP" | grep -c '^>' || true)" -eq 1 ]] \
    || die "IPIP 파일이 원본과 한 줄만 다르지 않습니다. 매니페스트 형식이 바뀌었을 수 있습니다: diff $CALICO_DIR/custom-resources.yaml $CR_IPIP" "$EXIT_FAIL"
  grep -q "cidr: ${POD_CIDR}" "$CR_IPIP" || die "custom-resources 의 cidr 이 클러스터 podCIDR(${POD_CIDR})과 다릅니다. 둘이 같아야 합니다." "$EXIT_FAIL"
  log_done "작성: $CR_IPIP"
}

need_typha_sg() {
  local cp wkid miss=()
  cp="$(sg_id "$CP_SG")"; wkid="$(sg_id "$WK_SG")"
  if [[ -z "$cp" || -z "$wkid" ]]; then REASON="CAPO 보안 그룹($CP_SG, $WK_SG)을 찾지 못함 — 4단계 필요"; return 0; fi
  typha_rule_present "$WK_SG" "$cp"   || miss+=("컨트롤플레인 출발지")
  typha_rule_present "$WK_SG" "$wkid" || miss+=("워커 출발지")
  if [[ "${#miss[@]}" -gt 0 ]]; then REASON="규칙 없음: ${miss[*]}"; return 0; fi
  REASON="규칙 2개 모두 있음"; return 1
}
capo_spec_has_typha() {   # 관리 클러스터의 OpenStackCluster 정의에 Typha 규칙이 있는가(CAPO 가 되돌리지 않는 위치)
  env -u KUBECONFIG "$KUBECTL" --context "$KUBE_CONTEXT" -n default get openstackcluster "$CLUSTER_NAME" -o json 2>/dev/null | python3 -c '
import sys, json
port = int(sys.argv[1])
try: o = json.load(sys.stdin)
except Exception: raise SystemExit(1)
rules = (o.get("spec", {}).get("managedSecurityGroups") or {}).get("clusterNodesSecurityGroupRules") or []
raise SystemExit(0 if any(r.get("protocol") == "tcp" and r.get("portRangeMin") == port and r.get("portRangeMax") == port for r in rules) else 1)' "$TYPHA_PORT"
}
do_typha_sg() {
  local cp wkid
  capo_spec_has_typha || log_warn "OpenStackCluster 정의에 Typha ${TYPHA_PORT}/tcp 규칙이 없습니다. 지금 넣는 규칙은 CAPO 가 되돌릴 수 있습니다(관찰됨). 4단계 주문서를 새로 렌더(FORCE_OVERWRITE_MANIFEST=1)해 클러스터를 다시 만들어야 영구적입니다."
  cp="$(sg_id "$CP_SG")"; wkid="$(sg_id "$WK_SG")"
  [[ -n "$cp" && -n "$wkid" ]] || die "CAPO 보안 그룹을 찾지 못했습니다. 4단계(클러스터 생성)를 먼저 실행하세요." "$EXIT_FAIL"
  typha_rule_present "$WK_SG" "$cp" || run_step "Typha 규칙(출발지 컨트롤플레인 SG)" os security group rule create "$WK_SG" --ingress --protocol tcp --dst-port "$TYPHA_PORT" --remote-group "$cp" --description "calico typha from controlplane (kit)" -c id -f value
  typha_rule_present "$WK_SG" "$wkid" || run_step "Typha 규칙(출발지 워커 SG)" os security group rule create "$WK_SG" --ingress --protocol tcp --dst-port "$TYPHA_PORT" --remote-group "$wkid" --description "calico typha from workers (kit)" -c id -f value
}

need_occm_secret() {
  if ! wk_up; then REASON="워크로드 클러스터에 접속할 수 없음 — 4단계 필요"; return 0; fi
  [[ -r "$CFG" ]] || { REASON="$CFG 를 읽을 수 없음"; return 0; }
  if ! wk -n kube-system get secret cloud-config >/dev/null 2>&1; then REASON="Secret 없음"; return 0; fi
  local sh; sh="$(secret_hash)"
  if [[ "$sh" != "$(conf_hash)" ]]; then REASON="Secret 내용이 clouds.yaml 에서 만든 설정과 다름(해시만 비교)"; return 0; fi
  REASON="Secret 이 있고 내용이 일치"; return 1
}
make_occm_secret() {   # $KIT_TMP/cloud.conf 로 Secret 생성·갱신. 값은 출력하지 않는다.
  "$KUBECTL" --kubeconfig "$CLUSTER_KUBECONFIG" -n kube-system create secret generic cloud-config --from-file=cloud.conf="$KIT_TMP/cloud.conf" --dry-run=client -o yaml \
    | "$KUBECTL" --kubeconfig "$CLUSTER_KUBECONFIG" apply -f - >/dev/null
}
do_occm_secret() {
  wk_up || die "워크로드 클러스터에 접속할 수 없습니다(${CLUSTER_KUBECONFIG}). 4단계를 먼저 실행하세요." "$EXIT_FAIL"
  local existed=0; wk -n kube-system get secret cloud-config >/dev/null 2>&1 && existed=1
  KIT_TMP="$(mktemp -d)"
  ( umask 077; gen_cloud_conf >"$KIT_TMP/cloud.conf" )
  grep -q '^enabled=false$' "$KIT_TMP/cloud.conf" || die "cloud.conf 에 [LoadBalancer] enabled=false 가 없습니다." "$EXIT_FAIL"
  grep -q '^auth-url=.\+' "$KIT_TMP/cloud.conf" || die "clouds.yaml 에서 ${KOLLA_CLOUD} 의 auth_url 을 읽지 못했습니다." "$EXIT_FAIL"
  run_step "OCCM 설정 Secret 생성·갱신(값은 출력하지 않음)" make_occm_secret
  rm -rf "$KIT_TMP"; KIT_TMP=""
  # OCCM 은 시작할 때만 설정을 읽는다. 이미 돌고 있었다면 재시작한다.
  if [[ "$existed" == "1" ]] && wk -n kube-system get ds openstack-cloud-controller-manager >/dev/null 2>&1; then
    run_step "OCCM 재시작(설정 변경 반영)" "$KUBECTL" --kubeconfig "$CLUSTER_KUBECONFIG" -n kube-system rollout restart ds/openstack-cloud-controller-manager
  fi
}

need_occm_deploy() {
  if ! wk_up; then REASON="워크로드 클러스터 없음"; return 0; fi
  if occm_ready; then
    local img; img="$(wk -n kube-system get ds openstack-cloud-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    if [[ "$img" == *":${OCCM_VERSION}" ]]; then REASON="DaemonSet 준비됨(이미지 ${img##*:})"; return 1; fi
    REASON="DaemonSet 이미지(${img:-없음})가 ${OCCM_VERSION} 이 아님"; return 0
  fi
  REASON="DaemonSet 없음 또는 준비 안 됨"; return 0
}
do_occm_deploy() {
  run_step "OCCM 매니페스트 적용" "$KUBECTL" --kubeconfig "$CLUSTER_KUBECONFIG" apply \
    -f "$OCCM_DIR/cloud-controller-manager-roles.yaml" -f "$OCCM_DIR/cloud-controller-manager-role-bindings.yaml" -f "$OCCM_DIR/openstack-cloud-controller-manager-ds.yaml"
  run_step "OCCM 롤아웃 대기" "$KUBECTL" --kubeconfig "$CLUSTER_KUBECONFIG" -n kube-system rollout status ds/openstack-cloud-controller-manager --timeout=180s
}

need_calico() {
  if ! wk_up; then REASON="워크로드 클러스터 없음"; return 0; fi
  local miss=()
  crd_present || miss+=("CRD")
  operator_present || miss+=("tigera-operator")
  installation_present || miss+=("Installation(default)")
  if [[ "${#miss[@]}" -gt 0 ]]; then REASON="없음: ${miss[*]}"; return 0; fi
  REASON="CRD, tigera-operator, Installation 모두 있음"; return 1
}
create_quiet() { "$KUBECTL" --kubeconfig "$CLUSTER_KUBECONFIG" create -f "$1" >/dev/null; }
do_calico() {
  crd_present || run_step "Calico CRD 생성(create, 3.5MB)" create_quiet "$CALICO_DIR/v3_projectcalico_org.yaml"
  operator_present || run_step "tigera-operator 생성" "$KUBECTL" --kubeconfig "$CLUSTER_KUBECONFIG" create -f "$CALICO_DIR/tigera-operator.yaml"
  installation_present || run_step "Calico custom-resources(${CALICO_ENCAP}) 생성" "$KUBECTL" --kubeconfig "$CLUSTER_KUBECONFIG" create -f "$CR_IPIP"
}

need_wait_ready() {
  if ! wk_up; then REASON="워크로드 클러스터 없음"; return 0; fi
  local p; p="$(problems)"
  if [[ -z "$p" ]]; then REASON="tigerastatus 전부 Available, 노드 Ready, 파드 정상, 테인트 없음"; return 1; fi
  REASON="준비 안 됨: ${p}"; return 0
}
do_wait_ready() {
  local waited=0 p=""
  log_info "최대 ${WAIT_CALICO_SECS}초 기다립니다(이미지 내려받기 포함)."
  while [[ "$waited" -lt "$WAIT_CALICO_SECS" ]]; do
    p="$(problems)"
    if [[ -z "$p" ]]; then log_done "모두 준비됨 (${waited}초)"; return 0; fi
    if (( waited % 60 == 0 )); then log_info "대기 중 ${waited}초: ${p}"; fi
    sleep 10; waited=$((waited + 10))
  done
  hint "${WAIT_CALICO_SECS}초 안에 준비되지 않음: ${p}" "OCCM 부터 확인: kubectl --kubeconfig ${CLUSTER_KUBECONFIG} -n kube-system get pods,describe ds/openstack-cloud-controller-manager. 그 다음 Typha 규칙(${TYPHA_PORT}/tcp), calico-node describe"
  die "5단계 준비 시간 초과" "$EXIT_FAIL"
}

# ------------------------------------------------------------------ 계획 수립
log_info "5단계 계획을 세웁니다 (로그: $KIT_LOG_FILE)"
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
  [[ " ${PLAN[*]} " == *" typha_sg "* ]]    && impact+=" OpenStack 의 CAPO 관리 보안 그룹(${WK_SG})에 ${TYPHA_PORT}/tcp 규칙 2개 추가;"
  [[ " ${PLAN[*]} " == *" occm_secret "* ]] && impact+=" 워크로드 클러스터에 OpenStack admin 자격 증명이 든 Secret 생성;"
  [[ " ${PLAN[*]} " == *" occm_deploy "* ]] && impact+=" OCCM 배포;"
  [[ " ${PLAN[*]} " == *" calico "* ]]      && impact+=" Calico 설치(약 13개 파드, 이미지 내려받기 포함);"
  confirm "$impact" "보안 그룹 규칙: 'openstack security group rule list ${WK_SG}' 에서 설명이 '(kit)' 인 규칙 삭제. 클러스터 안의 설치: 클러스터를 지우고 4단계부터 다시 하는 것이 가장 단순(kubectl delete cluster ${CLUSTER_NAME})"
fi

for id in "${PLAN[@]}"; do
  log_step "== ${TITLE[$id]}"
  "do_$id"
done

report_summary || true
log_done "5단계 실행 완료 (검증 b~e 는 stage5/verify-bcde.sh)"
