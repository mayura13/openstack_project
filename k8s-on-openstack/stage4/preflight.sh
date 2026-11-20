#!/usr/bin/env bash
# stage4/preflight.sh — 4단계 실행 전 점검. 읽기 전용.
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage4 preflight
KUBECTL="$BIN_DIR/kubectl"; OSC="$KOLLA_VENV/bin/openstack"; CFG="$KOLLA_CONFIG_DIR/clouds.yaml"
kc() { "$KUBECTL" --context "$KUBE_CONTEXT" "$@" 2>/dev/null || true; }
os() { OS_CLIENT_CONFIG_FILE="$CFG" timeout 60 "$OSC" --os-cloud "$KOLLA_CLOUD" "$@" 2>/dev/null || true; }
log_info "4단계 사전 점검을 시작합니다 (로그: $KIT_LOG_FILE)"

[[ "$(id -u)" -ne 0 ]] && check_ok "root 가 아닌 일반 계정" || check_ng "root 가 아닌 일반 계정" "일반 계정" "root" "kubeconfig 소유권이 어긋난다"
for t in kubectl:"$KUBECTL_VERSION" clusterctl:"$CLUSTERCTL_VERSION"; do
  name="${t%%:*}"; want="${t#*:}"; cur="$(tool_version "$name")"
  [[ "$cur" == "$want" ]] && check_ok "$name 버전" "$cur" || check_ng "$name 버전" "$want" "${cur:-없음}" "0단계 install 실행"
done

# ---------------------------------------------------------------- 3단계 산출물
if "$KUBECTL" --context "$KUBE_CONTEXT" get nodes >/dev/null 2>&1; then check_ok "관리 클러스터 접속" "$KUBE_CONTEXT"
else check_ng "관리 클러스터 접속" "$KUBE_CONTEXT 응답" "접속 불가" "3단계 apply 실행 또는 docker 그룹 재로그인"; fi
prov="$(kc get providers.clusterctl.cluster.x-k8s.io -A --no-headers | wc -l)"
[[ "${prov:-0}" -ge 4 ]] && check_ok "Cluster API provider" "${prov}개" || check_ng "Cluster API provider" ">= 4개" "${prov:-0}" "3단계 clusterctl init 미실행"

FWD_LINE="-s ${KIND_NET_CIDR} -d ${EXT_NET_CIDR} -o ${EXT_HOST_IF} -j ACCEPT"
# shellcheck disable=SC2086
sudo -n iptables -C FORWARD $FWD_LINE 2>/dev/null && check_ok "kind → 외부망 FORWARD 규칙" "$KIND_NET_CIDR → $EXT_NET_CIDR" \
  || check_ng "kind → 외부망 FORWARD 규칙" "$FWD_LINE" "없음 또는 확인 불가" "호스팅 방화벽이 6443 을 REJECT 한다. 3단계 apply 의 nat 단계"
sudo -n grep -qF -- "$FWD_LINE" "$HOST_NET_SCRIPT" 2>/dev/null && check_ok "FORWARD 규칙 영속화" || check_ng "FORWARD 규칙 영속화" "$HOST_NET_SCRIPT 에 줄 있음" "없음" "재부팅하면 규칙이 사라진다. 3단계 apply"

# ---------------------------------------------------------------- 2단계 산출물(OpenStack)
[[ -r "$CFG" ]] && check_ok "파일 읽기 가능" "$CFG" || check_ng "파일 읽기 가능: $CFG" "읽기 가능" "불가" "1단계 post-deploy"
grep -qE "^[[:space:]]+${KOLLA_CLOUD}:" "$CFG" 2>/dev/null && check_ok "clouds.yaml 의 cloud" "$KOLLA_CLOUD" || check_ng "clouds.yaml 의 cloud" "$KOLLA_CLOUD" "없음" "주문서의 cloudName 이 이 이름과 같아야 한다(프로젝트 범위 + internal)"
nets="$(os network list -f value -c Name | tr '\n' ' ')"
for n in "$EXT_NET_NAME" "$K8S_NET_NAME"; do grep -qw -- "$n" <<<"$nets" && check_ok "네트워크" "$n" || check_ng "네트워크: $n" "있음" "없음" "2단계 Terraform"; done
[[ -n "$(os subnet show k8s-subnet -c id -f value)" ]] && check_ok "서브넷" "k8s-subnet" || check_ng "서브넷: k8s-subnet" "있음" "없음" "2단계 Terraform"
[[ -n "$(os flavor show "$NODE_FLAVOR" -c id -f value)" ]] && check_ok "flavor" "$NODE_FLAVOR" || check_ng "flavor: $NODE_FLAVOR" "있음" "없음" "2단계 Terraform"
[[ -n "$(os keypair show "$NODE_KEYPAIR" -c name -f value)" ]] && check_ok "키페어" "$NODE_KEYPAIR" || check_ng "키페어: $NODE_KEYPAIR" "있음" "없음" "2단계 Terraform"
[[ "$(os image show "$NODE_IMAGE_NAME" -c status -f value)" == "active" ]] && check_ok "노드 이미지 active" "$NODE_IMAGE_NAME" || check_ng "노드 이미지 active" "active" "없음" "2단계 apply"
az="$(os availability zone list --compute -f value -c 'Zone Name' | tr '\n' ' ')"
grep -qw -- "$NODE_AZ" <<<"$az" && check_ok "가용 영역" "$NODE_AZ" || check_ng "가용 영역: $NODE_AZ" "$NODE_AZ 포함" "${az:-없음}" "versions.env 의 NODE_AZ 를 확인(openstack availability zone list --compute)"

# ---------------------------------------------------------------- 자원 여유(12 vCPU, 24GiB, 180GB)
thr="$(nproc 2>/dev/null || echo 0)"; mem="$(mem_total_gib)"; dsk="$(disk_avail_gib /)"
[[ "$thr" -ge 12 ]] && check_ok "CPU 스레드" "$thr" || check_ng "CPU 스레드" ">= 12" "$thr" "노드 VM 3대가 12 vCPU 를 쓴다"
[[ "${mem:-0}" -ge 32 ]] && check_ok "메모리" "${mem}GiB" || check_ng "메모리" ">= 32GiB" "${mem:-0}GiB" "노드 VM 3대가 24GiB 를 쓰고 OpenStack 자체도 쓴다"
[[ "${dsk:-0}" -ge 180 ]] && check_ok "디스크 여유(/)" "${dsk}GiB" || check_ng "디스크 여유(/)" ">= 180GiB" "${dsk:-0}GiB" "노드 VM 디스크 3개 합 180GB(thin 이라 실제 사용은 적을 수 있음)"

# ---------------------------------------------------------------- 인터넷
c="$(http_code "$ORC_URL")"
[[ "$c" =~ ^(200|301|302)$ ]] && check_ok "접속: ORC 매니페스트" "HTTP $c" || check_ng "접속: ORC 매니페스트" "응답 있음" "HTTP ${c:-없음}" "github.com 접근 확인"

# ---------------------------------------------------------------- 알림
"$KUBECTL" --context "$KUBE_CONTEXT" -n default get cluster "$CLUSTER_NAME" >/dev/null 2>&1 && check_warn "클러스터 $CLUSTER_NAME 가 이미 있음" "apply.sh 는 만들지 않고 준비 상태만 확인한다"

report_summary || die "점검 실패. 위 [FAIL] 항목을 해결한 뒤 다시 실행하세요." "$EXIT_FAIL"
log_done "4단계 사전 점검 통과"
