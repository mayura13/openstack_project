#!/usr/bin/env bash
# scripts/reset-lab.sh — 키트가 만든 것을 안쪽부터 차례로 지워 서버를 "깨끗한 상태"로 되돌린다(0~5단계 전체 재시험용).
# 기본은 계획만 출력한다(아무것도 바꾸지 않음). 지울 대상의 이름과 ID 를 먼저 보여 주고, --execute 로 승인한 뒤에만 지운다.
#
#   bash scripts/reset-lab.sh                      계획과 삭제 대상(이름, ID)만 출력
#   bash scripts/reset-lab.sh --execute            실행
# 옵션:
#   --with-docker        Docker(패키지, /var/lib/docker, /etc/docker)와 docker 그룹 구성원 자격까지 지움
#   --keep-node-image    노드 이미지 빌드 산출물(~/image-builder, ~/ib-venv, ~/ib-vars)을 남김(31분 빌드를 건너뜀)
#   --with-kolla-images  kolla-ansible destroy 에 --include-images 를 붙여 Kolla 이미지도 지움
#   --skip-terraform     OpenStack API 가 이미 죽어 있어 terraform destroy 를 못 할 때만. tfstate 와 실제 자원의 일치를 확인하지 못함
# 순서: 워크로드 클러스터(6단계) -> Terraform destroy+검증 -> kind -> Kolla destroy -> 상태 파일·설정·도구 -> 호스트 네트워크 -> (Docker)
# 지우지 않는 것: 물리 NIC 설정, 기존 방화벽 파일, ~/backup-*, ~/kit*, history, authorized_keys, 일반 apt 패키지, 호스트 이름
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
EXECUTE=0; WITH_DOCKER=0; KEEP_IMAGE=0; WITH_IMAGES=0; SKIP_TF=0; rest=()
for a in "$@"; do
  case "$a" in
    --execute) EXECUTE=1 ;;
    --with-docker) WITH_DOCKER=1 ;;
    --keep-node-image) KEEP_IMAGE=1 ;;
    --with-kolla-images) WITH_IMAGES=1 ;;
    --skip-terraform) SKIP_TF=1 ;;
    *) rest+=("$a") ;;
  esac
done
kit_parse_args "${rest[@]+"${rest[@]}"}"
kit_init reset reset-lab
[[ "$KIT_DRY_RUN" == "1" ]] && EXECUTE=0
# 자원 검증을 우회하는 --skip-terraform 은 허용하지 않는다(OpenStack 이 살아 있으면 destroy 와 이름·ID 확인을 반드시 거친다).
[[ "$SKIP_TF" == "0" ]] || die "--skip-terraform 은 tfstate 와 실제 자원의 일치를 확인하지 못해 허용하지 않습니다." "$EXIT_FAIL"

OPENRC="$KOLLA_CONFIG_DIR/admin-openrc.sh"
dk() { if docker ps >/dev/null 2>&1; then docker "$@"; else sudo -n docker "$@"; fi; }
os() { OS_CLIENT_CONFIG_FILE="$KOLLA_CONFIG_DIR/clouds.yaml" timeout 60 "$KOLLA_VENV/bin/openstack" --os-cloud "$KOLLA_CLOUD" "$@"; }
mkc() { env -u KUBECONFIG "$BIN_DIR/kubectl" --context "$KUBE_CONTEXT" "$@"; }
rule_present() { sudo -n iptables "$@" 2>/dev/null; }
safe_rm_home() {   # 홈 아래의 경로만 지운다. 백업과 키트 폴더, .ssh 전체, history 는 지우지 않는다
  local p="$1"
  [[ -n "$p" && "$p" == "$HOME"/* && "$p" != "$HOME/" ]] || die "홈 아래가 아닌 경로는 지우지 않습니다: '${p}'" "$EXIT_FAIL"
  case "$p" in
    "$HOME"/backup-*|"$HOME"/kit|"$HOME"/kit-*|"$HOME"/.ssh|"$HOME"/.bash_history|"$HOME"/.ssh/authorized_keys) die "보호 대상이라 지우지 않습니다: ${p}" "$EXIT_FAIL" ;;
  esac
  rm -rf -- "$p"
}
api_up() { [[ -r "$KOLLA_CONFIG_DIR/clouds.yaml" && -x "$KOLLA_VENV/bin/openstack" ]] && os token issue -f value -c id >/dev/null 2>&1; }
tf_state_count() {
  # 디렉터리나 실행 파일이 이미 없으면 지울 상태도 없다(이전 실행이 d_tf 까지 끝난 경우)
  if [[ ! -d "$TF_COMMON_DIR" || ! -x "$BIN_DIR/terraform" ]]; then echo 0; return 0; fi

  local state n
  state="$(cd "$TF_COMMON_DIR" && "$BIN_DIR/terraform" state list)" ||
    die "Terraform 상태 조회 실패: 삭제를 중단합니다" "$EXIT_FAIL"

  if [[ -z "$state" ]]; then
    n=0
  else
    n="$(printf '%s\n' "$state" | wc -l)"
  fi

  echo "$n"
}

FILTER_RULES=(
  "INPUT -i ${EXT_HOST_IF} -j ACCEPT"
  "INPUT -d ${KOLLA_VIP}/32 ! -i ${HOST_NIC} -j ACCEPT"
  "FORWARD -i ${EXT_HOST_IF} -o ${HOST_NIC} -j ACCEPT"
  "FORWARD -i ${HOST_NIC} -o ${EXT_HOST_IF} -m state --state RELATED,ESTABLISHED -j ACCEPT"
  "FORWARD -s ${KIND_NET_CIDR} -d ${EXT_NET_CIDR} -o ${EXT_HOST_IF} -j ACCEPT"
)
NAT_RULES=(
  "POSTROUTING -s ${EXT_NET_CIDR} -o ${HOST_NIC} -j MASQUERADE"
  "POSTROUTING -s ${KIND_NET_CIDR} -o ${HOST_NIC} -j MASQUERADE"
)
any_rule() {
  local r a
  for r in "${FILTER_RULES[@]}"; do read -ra a <<<"$r"; rule_present -C "${a[@]}" && return 0; done
  for r in "${NAT_RULES[@]}";    do read -ra a <<<"$r"; rule_present -t nat -C "${a[@]}" && return 0; done
  return 1
}
# 물리 NIC 의 주소·기본 경로가 바뀌지 않았는지 해시로만 비교한다(주소 값은 출력하지 않는다)
net_snapshot() { { ip -4 -o addr show dev "$HOST_NIC" 2>/dev/null || true; ip route show default 2>/dev/null || true; } | sha256sum | cut -c1-12; }

# ----------------------------------------------------------------- Terraform 자원 기록(이름, ID)
tf_resources() {   # type<TAB>name<TAB>id<TAB>openstack_name
  ( cd "$TF_COMMON_DIR" && "$BIN_DIR/terraform" show -json 2>/dev/null ) | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception as e:
    print(f"Terraform 상태 JSON 읽기 실패: {e}", file=sys.stderr)
    raise SystemExit(1)
def walk(m):
    for r in m.get("resources", []): yield r
    for c in m.get("child_modules", []): yield from walk(c)
for r in walk((d.get("values") or {}).get("root_module") or {}):
    v = r.get("values") or {}
    print("\t".join([r.get("type", ""), r.get("name", ""), str(v.get("id", "")), str(v.get("name", ""))]))'
}
os_ids_for_type() {   # 해당 종류의 현재 ID 목록. 조회에 실패하면 비정상 종료한다(실패를 "없음"으로 읽지 않기 위해)
  case "$1" in
    openstack_networking_network_v2) os network list -f value -c ID ;;
    openstack_networking_subnet_v2)  os subnet list -f value -c ID ;;
    openstack_networking_router_v2)  os router list -f value -c ID ;;
    openstack_compute_flavor_v2)     os flavor list -f value -c ID ;;
    openstack_compute_keypair_v2)    os keypair list -f value -c Name ;;
    openstack_images_image_v2)       os image list -f value -c ID ;;
    *) return 3 ;;
  esac
}
tf_key() { [[ "$1" == "openstack_compute_keypair_v2" ]] && echo "$3" || echo "$2"; }   # tf_key <type> <id> <name>
print_tf_table() {   # print_tf_table <기록파일> [live]
  local f="$1" live="${2:-}" t n i o state ids
  printf '    %-42s %-20s %-38s %s\n' "종류" "이름(tf)" "ID" "$([[ -n "$live" ]] && echo 'OpenStack 에 있는가')"
  while IFS=$'\t' read -r t n i o; do
    state=""
    if [[ -n "$live" ]]; then
      if [[ "$t" == "openstack_networking_router_interface_v2" ]]; then state="(라우터와 함께 정리됨)"
      elif ids="$(os_ids_for_type "$t" 2>/dev/null)"; then grep -qxF "$(tf_key "$t" "$i" "$o")" <<<"$ids" && state="있음" || state="없음(상태와 불일치)"
      else state="확인 불가"; fi
    fi
    printf '    %-42s %-20s %-38s %s\n' "$t" "$n" "${i:0:36}" "$state"
  done <"$f"
}

# ----------------------------------------------------------------- 삭제 대상 보고(읽기 전용)
show_targets() {
  log_info "===== 삭제 대상과 영향 범위(읽기 전용) ====="
  # 1. 워크로드 클러스터와 노드 VM
  if [[ -x "$BIN_DIR/kubectl" ]] && mkc -n default get cluster "$CLUSTER_NAME" >/dev/null 2>&1; then
    log_info "[1] 워크로드 클러스터 ${CLUSTER_NAME}: 있음(관리 클러스터 ${KUBE_CONTEXT}). 6단계로 삭제합니다."
  else log_info "[1] 워크로드 클러스터 ${CLUSTER_NAME}: 없음(또는 관리 클러스터에 접속 불가)"; fi
  if api_up; then
    log_info "    OpenStack 서버(ID, 이름, 상태):"; os server list -f value -c ID -c Name -c Status 2>/dev/null | sed 's/^/      /' || true
  else log_info "    OpenStack API 에 접속할 수 없어 서버 목록을 보지 못했습니다."; fi
  # 2. Terraform
  local tf; tf="$(mktemp)"
  if [[ -d "$TF_COMMON_DIR" && -x "$BIN_DIR/terraform" ]]; then
    tf_resources >"$tf" || true
    log_info "[2] Terraform 상태 ${TF_COMMON_DIR}/terraform.tfstate: 자원 $(grep -c . "$tf" || true)개(예상 ${TF_RESOURCE_COUNT}개)"
    if [[ -s "$tf" ]]; then if api_up; then print_tf_table "$tf" live; else print_tf_table "$tf"; fi; fi
  else log_info "[2] Terraform 상태: 없음"; fi
  rm -f "$tf"
  # 3. kind, 4. Docker
  if have_cmd kind && dk ps >/dev/null 2>&1; then log_info "[3] kind 클러스터: $(kind get clusters 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"; else log_info "[3] kind 클러스터: 확인 불가 또는 없음"; fi
  if have_cmd docker && dk ps -a >/dev/null 2>&1; then
    log_info "[4] Docker 컨테이너 $(dk ps -a -q | wc -l | tr -d ' ')개, 이미지 $(dk images -q | wc -l | tr -d ' ')개 (Kolla 컨테이너와 kind 노드 포함)"
  else log_info "[4] Docker: 확인 불가 또는 없음"; fi
  # 5. libvirt(참고). 키트가 만든 것이 아니라 지우지 않는다
  if have_cmd virsh; then
    log_info "[5] libvirt(참고, 이 스크립트는 지우지 않음) VM: $(timeout 10 virsh -c qemu:///system list --all --name 2>/dev/null | sed '/^$/d' | tr '\n' ' ')"
    log_info "    네트워크: $(timeout 10 virsh -c qemu:///system net-list --all --name 2>/dev/null | sed '/^$/d' | tr '\n' ' ') / 스토리지 풀: $(timeout 10 virsh -c qemu:///system pool-list --all --name 2>/dev/null | sed '/^$/d' | tr '\n' ' ')"
  fi
  # 6. 호스트 네트워크
  local r a n=0; for r in "${FILTER_RULES[@]}"; do read -ra a <<<"$r"; rule_present -C "${a[@]}" && n=$((n+1)); done
  for r in "${NAT_RULES[@]}"; do read -ra a <<<"$r"; rule_present -t nat -C "${a[@]}" && n=$((n+1)); done
  log_info "[6] 호스트 네트워크: ${KOLLA_NET_IF} $(ip link show "$KOLLA_NET_IF" >/dev/null 2>&1 && echo 있음 || echo 없음), ${EXT_IF} $(ip link show "$EXT_IF" >/dev/null 2>&1 && echo 있음 || echo 없음), 키트가 넣은 iptables 규칙 ${n}개, 유닛 $([[ -e $HOST_NET_UNIT ]] && echo 있음 || echo 없음)"
  log_info "    보존: 물리 NIC ${HOST_NIC} 주소·기본 경로(해시 $(net_snapshot)), 기존 방화벽 파일, ~/backup-*, ~/kit*, history, authorized_keys"
  log_info "===== 보고 끝 ====="
}

# ----------------------------------------------------------------- 단계별 조건과 동작
p_cluster() {
  # 이전 실행이 중간에 끊겼다면 kubectl/kind 가 이미 없을 수 있다. 관리 클러스터가 없으면 지울 워크로드도 없다.
  if ! have_cmd kind || [[ ! -x "$BIN_DIR/kubectl" ]]; then return 1; fi
  dk ps >/dev/null 2>&1 || die "Docker 조회 실패. 관리 클러스터 확인 불가: Reset 중단" "$EXIT_FAIL"
  kind get clusters 2>/dev/null | grep -qxF "$KIND_CLUSTER" || return 1

  mkc -n default get clusters.cluster.x-k8s.io >/dev/null 2>&1 ||
    die "Kubernetes 관리 API 조회 실패. 삭제 중단" "$EXIT_FAIL"

  if mkc -n default get cluster "$CLUSTER_NAME" >/dev/null 2>&1; then
    return 0
  fi

  if mkc -n default get cluster "$CLUSTER_NAME" --ignore-not-found -o name 2>/dev/null |
     grep -qx "cluster.cluster.x-k8s.io/$CLUSTER_NAME"; then
    return 0
  fi

  local result
  result="$(mkc -n default get cluster "$CLUSTER_NAME" --ignore-not-found -o name)" ||
    die "클러스터 조회 실패. 삭제 중단" "$EXIT_FAIL"

  [[ -z "$result" ]] ||
    die "클러스터 조회 결과가 예상과 다릅니다: $result" "$EXIT_FAIL"

  return 1
}
d_cluster() {
  log_step "워크로드 클러스터 ${CLUSTER_NAME} 삭제(6단계 apply: 삭제 전후 기록, 클러스터 이름 입력 확인, OpenStack 정리 대기)"

  bash "$KIT_ROOT/stage6/apply.sh" ||
    die "6단계 삭제 또는 검증 실패: Terraform 단계로 진행하지 않습니다." "$EXIT_FAIL"

  # Stage 6 성공 이후에도 현재 API 상태를 재검증한다.
  mkc -n default get clusters.cluster.x-k8s.io >/dev/null ||
    die "관리 클러스터 API 조회 실패: Terraform 삭제 중단" "$EXIT_FAIL"

  local cluster_result
  cluster_result="$(mkc -n default get cluster "$CLUSTER_NAME" --ignore-not-found -o name)" ||
    die "워크로드 클러스터 조회 실패: Terraform 삭제 중단" "$EXIT_FAIL"

  [[ -z "$cluster_result" ]] ||
    die "워크로드 클러스터가 아직 남아 있습니다: $cluster_result" "$EXIT_FAIL"

  local before="$STAGE6_DIR/before"
  [[ -s "$before/api_fip.txt" && -s "$before/capo_ports.json" ]] ||
    die "삭제 전 CAPO 기록이 없어 완료 여부를 검증할 수 없습니다." "$EXIT_FAIL"

  local fip remaining
  fip="$(cat "$before/api_fip.txt")"

  # Stage 6에서 검증한 동일한 소유 자원 검사 함수를 사용한다.
  (
    source "$KIT_ROOT/stage6/lib6.sh"
    BEFORE="$before"
    remaining="$(owned_left "$fip")"
    [[ -z "$remaining" ]] || {
      printf 'CAPO 잔여 자원 또는 조회 실패: %s\n' "$remaining" >&2
      exit 1
    }
  ) || die "CAPO 잔여 자원 검증 실패: Terraform 삭제 중단" "$EXIT_FAIL"

  log_done "워크로드 클러스터 및 CAPO 자원 정리 재검증 완료"
}

p_tfd() {
  [[ "$SKIP_TF" == "0" ]] || return 1
  [[ -d "$TF_COMMON_DIR" && -x "$BIN_DIR/terraform" ]] || return 1
  local n
  n="$(tf_state_count)" || die "Terraform 상태 조회 실패: Reset 중단" "$EXIT_FAIL"
  [[ "$n" -gt 0 ]]
}
verify_tf_addresses() {
  local actual
  actual="$(cd "$TF_COMMON_DIR" && "$BIN_DIR/terraform" state list)" ||
    die "Terraform 상태 주소 조회 실패" "$EXIT_FAIL"

  TF_ACTUAL_ADDRESSES="$actual" python3 - <<'PYVERIFY'
import os
import sys

expected = {
    "openstack_compute_flavor_v2.node",
    "openstack_compute_keypair_v2.node",
    "openstack_images_image_v2.node",
    "openstack_networking_network_v2.ext",
    "openstack_networking_network_v2.k8s",
    "openstack_networking_router_interface_v2.k8s",
    "openstack_networking_router_v2.k8s",
    "openstack_networking_subnet_v2.ext",
    "openstack_networking_subnet_v2.k8s",
}

lines = os.environ["TF_ACTUAL_ADDRESSES"].splitlines()
actual = set(lines)

if len(lines) != len(expected) or actual != expected:
    print("[FAIL] Terraform 상태 주소가 예상 목록과 다릅니다.", file=sys.stderr)
    print("누락:", sorted(expected - actual), file=sys.stderr)
    print("추가:", sorted(actual - expected), file=sys.stderr)
    sys.exit(1)

print("[PASS] Terraform 상태 주소 9개 정확히 일치")
PYVERIFY
  local rc=$?
  [[ "$rc" -eq 0 ]] ||
    die "Terraform 상태 주소 검증 실패: 삭제 중단" "$EXIT_FAIL"
}


verify_tf_destroy_plan() {
  local plan_file="$1"
  local json_file="$2"

  [[ -s "$plan_file" ]] ||
    die "Terraform 저장 계획 파일이 없습니다" "$EXIT_FAIL"

  (
    cd "$TF_COMMON_DIR" &&
    umask 077 &&
    "$BIN_DIR/terraform" show -json "$plan_file" >"$json_file"
  ) || die "Terraform 계획 JSON 조회 실패" "$EXIT_FAIL"

  if python3 - "$json_file" <<'PYPLAN'
import json
import sys

expected = {
    "openstack_compute_flavor_v2.node",
    "openstack_compute_keypair_v2.node",
    "openstack_images_image_v2.node",
    "openstack_networking_network_v2.ext",
    "openstack_networking_network_v2.k8s",
    "openstack_networking_router_interface_v2.k8s",
    "openstack_networking_router_v2.k8s",
    "openstack_networking_subnet_v2.ext",
    "openstack_networking_subnet_v2.k8s",
}

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)

    changes = data["resource_changes"]
    if not isinstance(changes, list):
        raise ValueError("resource_changes가 배열이 아닙니다")

    addresses = []
    for item in changes:
        address = item["address"]
        actions = item["change"]["actions"]

        if not isinstance(address, str) or actions != ["delete"]:
            raise ValueError(f"허용되지 않은 작업: {address}: {actions}")

        addresses.append(address)

    if len(addresses) != len(expected):
        raise ValueError(
            f"삭제 자원 개수 불일치: {len(addresses)}개"
        )

    if set(addresses) != expected:
        raise ValueError(
            f"삭제 주소 불일치: "
            f"누락={sorted(expected - set(addresses))}, "
            f"추가={sorted(set(addresses) - expected)}"
        )

except (OSError, ValueError, KeyError, TypeError) as exc:
    print(f"[FAIL] Terraform 삭제 계획 검증 실패: {exc}", file=sys.stderr)
    sys.exit(1)

print("[PASS] Terraform 삭제 계획: 정확한 9개 자원, 모두 delete")
PYPLAN
  then
    log_done "Terraform 삭제 계획 JSON 검증 통과"
  else
    die "Terraform 삭제 계획 검증 실패: 삭제 중단" "$EXIT_FAIL"
  fi
}

tf_plan_cleanup() {
  local dir="${1:-}"
  local base

  [[ -n "$dir" ]] || return 1

  base="$(basename -- "$dir")"

  [[ "$dir" == /tmp/openinfra-tfplan.* &&
     "$base" == openinfra-tfplan.* &&
     "$dir" == "/tmp/$base" ]] || {
    printf 'FAIL: 예상하지 못한 Terraform 임시 경로: %s\n' "$dir" >&2
    return 1
  }

  [[ -d "$dir" && ! -L "$dir" ]] || return 1

  rm -rf -- "$dir"
}


d_tfd() {
  # Terraform 네트워크 삭제 전 CAPO 객체와 소유 자원을 독립적으로 검증한다.
  mkc -n default get clusters.cluster.x-k8s.io >/dev/null ||
    die "관리 클러스터 API 조회 실패: Terraform 삭제 중단" "$EXIT_FAIL"

  local cluster_result
  cluster_result="$(mkc -n default get cluster "$CLUSTER_NAME" --ignore-not-found -o name)" ||
    die "CAPO 클러스터 조회 실패: Terraform 삭제 중단" "$EXIT_FAIL"

  [[ -z "$cluster_result" ]] ||
    die "CAPO 클러스터 객체가 남아 있습니다: $cluster_result" "$EXIT_FAIL"

  local before="$STAGE6_DIR/before"
  [[ -s "$before/api_fip.txt" && -s "$before/capo_ports.json" ]] ||
    die "Stage6 삭제 전 CAPO 기록이 없습니다: Terraform 삭제 중단" "$EXIT_FAIL"

  local fip remaining
  fip="$(cat "$before/api_fip.txt")"
  [[ -n "$fip" ]] ||
    die "Stage6 API Floating IP 기록이 비어 있습니다" "$EXIT_FAIL"

  (
    source "$KIT_ROOT/stage6/lib6.sh"
    BEFORE="$before"
    remaining="$(owned_left "$fip")"
    [[ -z "$remaining" ]] || {
      printf 'CAPO 잔여 자원 또는 조회 실패: %s\n' "$remaining" >&2
      exit 1
    }
  ) || die "CAPO 잔여 자원 검증 실패: Terraform 삭제 중단" "$EXIT_FAIL"

  verify_tf_addresses

  api_up || die "OpenStack API 에 접속하지 못해 Terraform 자원을 지울 수 없습니다. 서비스가 죽어 있다면 --skip-terraform 으로 건너뛸 수 있지만, 그러면 상태 파일과 실제 자원이 일치하는지 확인하지 못합니다." "$EXIT_FAIL"
  mkdir -p "$KIT_LOG_DIR"; local rec="$KIT_LOG_DIR/reset-tf-resources-$(date +%Y%m%d-%H%M%S).tsv" n
  tf_resources >"$rec" ||
    die "Terraform 상태 기록 실패: 삭제를 중단합니다." "$EXIT_FAIL"
  n="$(grep -c . "$rec" || true)"
  [[ "$n" -gt 0 ]] || die "Terraform 상태에서 자원을 읽지 못했습니다(terraform show -json 실패)." "$EXIT_FAIL"
  [[ "$n" -eq "$TF_RESOURCE_COUNT" ]] || die "Terraform 자원 수가 예상과 다릅니다. 수동 검토 필요." "$EXIT_FAIL"
  local t nm i o ids
  while IFS=$'\t' read -r t nm i o; do
    [[ "$t" == "openstack_networking_router_interface_v2" ]] && continue
    ids="$(os_ids_for_type "$t")" || die "Terraform 자원 조회 실패: $t" "$EXIT_FAIL"
    grep -qxF "$(tf_key "$t" "$i" "$o")" <<<"$ids" || die "Terraform 상태와 실제 자원이 불일치: $t $nm $i" "$EXIT_FAIL"
  done <"$rec"
  log_info "Terraform 이 지울 자원 ${n}개(기록: ${rec}):"; print_tf_table "$rec" live
  [[ "$n" -eq "$TF_RESOURCE_COUNT" ]] || log_warn "자원 수가 예상(${TF_RESOURCE_COUNT}개)과 다릅니다. 위 표가 지울 대상이 맞는지 확인하세요."
  # 계획 생성·검증·적용은 별도 서브셸에서 수행한다.
  # 오류 종료 시에도 민감한 임시 파일을 정리한다.
  (
    set -Eeuo pipefail

    local plan_dir plan_file plan_output plan
    plan_dir="$(mktemp -d /tmp/openinfra-tfplan.XXXXXXXX)" ||
      die "Terraform 계획 임시 디렉터리 생성 실패" "$EXIT_FAIL"

    trap 'tf_plan_cleanup "$plan_dir"' EXIT

    chmod 700 "$plan_dir"
    plan_file="$plan_dir/destroy.tfplan"

    if ! (
      cd "$TF_COMMON_DIR" &&
      . "$OPENRC" &&
      umask 077 &&
      "$BIN_DIR/terraform" plan -destroy -input=false -no-color -out="$plan_file"
    ) >"$plan_dir/plan.log" 2>&1; then
      die "Terraform 삭제 계획 생성 실패" "$EXIT_FAIL"
    fi

    plan_output="$(cd "$TF_COMMON_DIR" &&
      "$BIN_DIR/terraform" show -no-color "$plan_file")" ||
      die "저장된 Terraform 계획 조회 실패" "$EXIT_FAIL"

    plan="$(grep -E '^Plan:' <<<"$plan_output" | tail -n1)"

    if [[ -z "$plan" ]] ||
       ! grep -Eq "^Plan: 0 to add, 0 to change, ${n} to destroy\." <<<"$plan"; then
      die "저장된 Terraform 계획의 삭제 개수가 예상(${n}개)과 다릅니다." "$EXIT_FAIL"
    fi

    verify_tf_destroy_plan "$plan_file" "$plan_dir/destroy.json"

    log_info "저장된 Terraform 삭제 계획: $plan"

    if [[ "${KIT_CONFIRM_TFDESTROY:-}" != "destroy" ]]; then
      [[ -t 0 ]] ||
        die "Terraform 삭제 확인에 터미널이 필요합니다." "$EXIT_USAGE"

      local ans
      read -r -p "위 Terraform 자원 ${n}개를 삭제하려면 destroy 입력: " ans

      [[ "$ans" == "destroy" ]] ||
        die "삭제 확인이 일치하지 않습니다." "$EXIT_FAIL"
    fi

    run_step "terraform saved-plan apply(${n}개)" \
      bash -c 'cd "$1" && . "$2" && "$3" apply -input=false -auto-approve "$4"' \
      _ "$TF_COMMON_DIR" "$OPENRC" "$BIN_DIR/terraform" "$plan_file"
  )

  # 지워졌는지를 목록 조회로 확인한다. 조회에 실패하면 지워졌다고 보지 않는다.
  local t nm i o ids left=0
  while IFS=$'\t' read -r t nm i o; do
    [[ "$t" == "openstack_networking_router_interface_v2" ]] && continue
    ids="$(os_ids_for_type "$t")" || die "${t} 목록을 조회하지 못해 삭제 여부를 확인할 수 없습니다. tfstate 를 지우지 않고 중단합니다." "$EXIT_FAIL"
    if grep -qxF "$(tf_key "$t" "$i" "$o")" <<<"$ids"; then log_warn "아직 남아 있음: ${t} ${nm} ${i:0:36}"; left=$((left+1)); fi
  done <"$rec"
  [[ "$left" -eq 0 ]] || die "Terraform 자원 ${left}개가 OpenStack 에 남아 있습니다. tfstate 는 그대로 둡니다. 원인(예: 포트가 아직 물려 있음)을 확인하고 다시 실행하세요." "$EXIT_FAIL"
  local remaining
  remaining="$(tf_state_count)" || die "Terraform 상태 재조회 실패: Reset 중단" "$EXIT_FAIL"
  [[ "$remaining" -eq 0 ]] || die "terraform state 에 항목이 남아 있습니다. tfstate 를 지우지 않고 중단합니다." "$EXIT_FAIL"
  log_done "Terraform 자원 ${n}개가 OpenStack 에서 사라졌고 상태도 비었음을 확인했습니다."
}

p_kind() {
  have_cmd kind || return 1

  dk ps >/dev/null 2>&1 ||
    die "Docker 조회 실패. 관리 클러스터 확인 불가: Reset 중단" "$EXIT_FAIL"

  local clusters
  clusters="$(kind get clusters)" ||
    die "kind 클러스터 목록 조회 실패: Reset 중단" "$EXIT_FAIL"

  grep -qxF "$KIND_CLUSTER" <<<"$clusters"
}
d_kind() {
  [[ -x "$BIN_DIR/kubectl" ]] ||
    die "kubectl 실행 파일이 없습니다: kind 삭제 중단" "$EXIT_FAIL"

  mkc -n default get clusters.cluster.x-k8s.io >/dev/null ||
    die "관리 클러스터 API 조회 실패: kind 삭제 중단" "$EXIT_FAIL"

  local cluster_result
  cluster_result="$(mkc -n default get cluster "$CLUSTER_NAME" --ignore-not-found -o name)" ||
    die "워크로드 클러스터 조회 실패: kind 삭제 중단" "$EXIT_FAIL"

  [[ -z "$cluster_result" ]] ||
    die "워크로드 클러스터가 아직 남아 있습니다: $cluster_result" "$EXIT_FAIL"
  api_up || die "OpenStack API 조회 실패: kind 삭제 중단" "$EXIT_FAIL"
  local servers; servers="$(os server list -f value -c Name)" || die "서버 목록 조회 실패" "$EXIT_FAIL"
  ! grep -q "^${CLUSTER_NAME}-" <<<"$servers" || die "워크로드 서버가 남아 있습니다" "$EXIT_FAIL"
  local remaining
  remaining="$(tf_state_count)" ||
    die "Terraform 상태 조회 실패: kind 삭제 중단" "$EXIT_FAIL"

  [[ "$remaining" == "0" ]] ||
    die "Terraform state에 자원 ${remaining}개가 남아 있습니다: kind 삭제 중단" "$EXIT_FAIL"

  run_step "kind 관리 클러스터 ${KIND_CLUSTER} 삭제" kind delete cluster --name "$KIND_CLUSTER"
}

p_kolla() {   # kind 노드(${KIND_CLUSTER}-*) 말고 컨테이너가 있으면 Kolla 가 남은 것이다
  have_cmd docker || return 1
  dk ps >/dev/null 2>&1 || die "Docker 조회 실패. Kolla 컨테이너 확인 불가: Reset 중단" "$EXIT_FAIL"
  dk ps -a --format '{{.Names}}' | grep -qvE "^(${KIND_CLUSTER}-|$)"
}
d_kolla() {
  [[ -x "$KOLLA_VENV/bin/kolla-ansible" ]] || die "kolla-ansible 이 없습니다(${KOLLA_VENV}). 컨테이너는 있는데 도구가 없으니 직접 정리해야 합니다." "$EXIT_FAIL"
  [[ -f "$KOLLA_INVENTORY" ]] || die "인벤토리가 없습니다(${KOLLA_INVENTORY})." "$EXIT_FAIL"
  api_up || die "OpenStack API 조회 실패: Kolla 삭제 중단" "$EXIT_FAIL"
  local remaining
  remaining="$(tf_state_count)" || die "Terraform 상태 조회 실패: Kolla 삭제 중단" "$EXIT_FAIL"
  [[ "$remaining" -eq 0 ]] || die "Terraform 상태가 남아 있어 Kolla 삭제 중단" "$EXIT_FAIL"

  # OpenStack VM이 하나라도 남아 있으면 Kolla 서비스 삭제 금지
  local servers
  servers="$(os server list -f value -c ID)" ||
    die "OpenStack VM 목록 조회 실패: Kolla 삭제 중단" "$EXIT_FAIL"

  [[ -z "$servers" ]] ||
    die "OpenStack VM이 아직 남아 있습니다. Kolla 삭제 중단: $servers" "$EXIT_FAIL"

  use_kolla_venv
  local extra=(); [[ "$WITH_IMAGES" == "1" ]] && extra=(--include-images)
  KIT_SCREEN_FILTER='PLAY \[|PLAY RECAP|failed=[1-9]|fatal' run_step "kolla-ansible destroy(OpenStack 컨테이너, 볼륨 삭제)" \
    kolla-ansible destroy -i "$KOLLA_INVENTORY" --yes-i-really-really-mean-it "${extra[@]+"${extra[@]}"}"
}

p_tf() { [[ -d "$TF_COMMON_DIR" ]]; }
d_tf() {
  local n
  n="$(tf_state_count)" || die "Terraform 상태 조회 실패: 디렉터리 삭제 중단" "$EXIT_FAIL"
  if [[ "$n" -gt 0 ]]; then
    if api_up; then die "terraform state 에 ${n}개가 남아 있고 OpenStack 도 살아 있습니다. destroy 없이 상태 파일을 지우지 않습니다." "$EXIT_FAIL"; fi
    log_warn "terraform state 에 ${n}개가 남아 있지만 OpenStack 이 이미 없어 실제 자원은 없습니다(기록만 지움)."
  fi
  log_step "Terraform 디렉터리 삭제: $TF_COMMON_DIR"; safe_rm_home "$TF_COMMON_DIR"
}
p_image() { [[ "$KEEP_IMAGE" == "0" ]] && { [[ -e "$IB_DIR" || -e "$IB_VENV" || -e "$IB_VARS_DIR" ]]; }; }
d_image() { log_step "노드 이미지 빌드 산출물 삭제: $IB_DIR, $IB_VENV, $IB_VARS_DIR"; safe_rm_home "$IB_DIR"; safe_rm_home "$IB_VENV"; safe_rm_home "$IB_VARS_DIR"; }
p_key()   { [[ -e "$NODE_KEY" || -e "${NODE_KEY}.pub" ]]; }
d_key()   { log_step "노드 SSH 키 삭제: $NODE_KEY(.pub) — 2단계가 새로 만든다"; safe_rm_home "$NODE_KEY"; safe_rm_home "${NODE_KEY}.pub"; }
p_capi()  { [[ -e "$CAPI_DIR" ]]; }
d_capi()  { log_step "주문서, kubeconfig, 매니페스트, 삭제 전후 기록 폴더 삭제: $CAPI_DIR"; safe_rm_home "$CAPI_DIR"; }
p_kcfg()  { [[ -e /etc/kolla || -e "$KOLLA_INVENTORY" ]]; }
d_kcfg()  {
  [[ "$KOLLA_CONFIG_DIR" == "/etc/kolla" ]] || die "KOLLA_CONFIG_DIR 가 /etc/kolla 가 아니라 지우지 않습니다: ${KOLLA_CONFIG_DIR}" "$EXIT_FAIL"
  log_step "Kolla 설정 삭제: /etc/kolla(globals.yml, passwords.yml, clouds.yaml 포함), ${KOLLA_INVENTORY}"
  sudo rm -rf -- /etc/kolla; [[ -e "$KOLLA_INVENTORY" ]] && safe_rm_home "$KOLLA_INVENTORY"; return 0
}
p_venv()  { [[ -d "$KOLLA_VENV" ]]; }
d_venv()  { log_step "Kolla 가상환경 삭제: $KOLLA_VENV"; safe_rm_home "$KOLLA_VENV"; }
p_tools() { local t; for t in kubectl terraform kind clusterctl; do [[ -e "$BIN_DIR/$t" ]] && return 0; done; return 1; }
d_tools() { local t; log_step "도구 4종 삭제: ${BIN_DIR}/{kubectl,terraform,kind,clusterctl}"; for t in kubectl terraform kind clusterctl; do sudo rm -f -- "$BIN_DIR/$t"; done; }

p_hostnet() {
  any_rule && return 0
  ip link show "$KOLLA_NET_IF" >/dev/null 2>&1 && return 0
  ip link show "$EXT_IF" >/dev/null 2>&1 && return 0
  [[ -e "$HOST_NET_UNIT" || -e "$HOST_NET_SCRIPT" || -e "$HOST_NET_SYSCTL" ]]
}
d_hostnet() {
  log_step "호스트 네트워크 정리: 서비스 ${HOST_NET_UNIT##*/}, 인터페이스 ${KOLLA_NET_IF}/${EXT_IF}, 키트가 넣은 iptables 규칙, 관련 파일"
  local before after r a i d; before="$(net_snapshot)"
  sudo systemctl disable --now "${HOST_NET_UNIT##*/}" 2>/dev/null || true
  for r in "${FILTER_RULES[@]}"; do read -ra a <<<"$r"; for i in 1 2 3; do rule_present -C "${a[@]}" && sudo iptables -D "${a[@]}" || break; done; done
  for r in "${NAT_RULES[@]}";    do read -ra a <<<"$r"; for i in 1 2 3; do rule_present -t nat -C "${a[@]}" && sudo iptables -t nat -D "${a[@]}" || break; done; done
  for d in "$EXT_IF" "$KOLLA_NET_IF"; do
    [[ "$d" != "$HOST_NIC" ]] || die "지울 인터페이스가 물리 NIC(${HOST_NIC})와 같습니다. 중단합니다." "$EXIT_FAIL"
    ip link show "$d" >/dev/null 2>&1 && sudo ip link del "$d" || true
  done
  if ! pgrep -x ovs-vswitchd >/dev/null 2>&1; then   # OVS 가 없는데 남은 가상 장치. 실패해도 계속
    for d in br-ex br-int br-tun; do ip link show "$d" >/dev/null 2>&1 && { sudo ip link del "$d" 2>/dev/null || log_warn "$d 를 지우지 못했습니다(재부팅 전까지 남을 수 있음)"; }; done
  fi
  sudo rm -f -- "$HOST_NET_UNIT" "$HOST_NET_SCRIPT" "$HOST_NET_SCRIPT".bak-* "$HOST_NET_SYSCTL"
  sudo systemctl daemon-reload
  after="$(net_snapshot)"
  [[ "$before" == "$after" ]] && log_done "물리 NIC ${HOST_NIC} 의 주소·기본 경로가 그대로입니다(해시 ${after})" \
    || log_warn "물리 NIC ${HOST_NIC} 의 주소 또는 기본 경로가 바뀌었습니다(해시 ${before} -> ${after}). SSH 가 살아 있는지, ip route 를 확인하세요."
}

p_docker() { [[ "$WITH_DOCKER" == "1" ]] && { have_cmd docker || [[ -e /var/lib/docker || -e /etc/docker ]]; }; }
d_docker() {
  log_step "Docker 제거: 패키지, /var/lib/docker, /var/lib/containerd, /etc/docker, docker 그룹 구성원 자격"
  local pk=() p
  sudo systemctl stop docker.socket docker.service containerd.service 2>/dev/null || true
  for p in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras docker.io; do dpkg -s "$p" >/dev/null 2>&1 && pk+=("$p"); done
  [[ "${#pk[@]}" -gt 0 ]] && run_step "apt purge ${pk[*]}" sudo apt-get purge -y "${pk[@]}"
  sudo rm -rf -- /var/lib/docker /var/lib/containerd /etc/docker
  sudo rm -f -- /etc/systemd/system/docker.service.d/kolla.conf
  sudo systemctl daemon-reload
  if user_in_group_db docker; then sudo gpasswd -d "$(id -un)" docker; log_warn "docker 그룹에서 제외했습니다. 현재 세션에는 남아 있으니 로그아웃 후 다시 접속하세요."; fi
}

PLANNED=0
step() {   # step <제목> <조건함수> <동작함수>
  local title="$1" present="$2" fn="$3" rc

  if (
    die() {
      printf 'RESET CHECK FAILED: %s\n' "$1" >&2
      exit 90
    }
    "$present"
  ); then
    rc=0
  else
    rc=$?
  fi

  case "$rc" in
    0)
      PLANNED=$((PLANNED + 1))
      if [[ "$EXECUTE" == "1" ]]; then
        "$fn"
      else
        log_info "[삭제 예정] $title"
      fi
      ;;
    1)
      log_skip "$title — 대상 없음"
      ;;
    *)
      die "삭제 대상 확인 실패: $title (종료 코드: $rc)" "$EXIT_FAIL"
      ;;
  esac
}
run_all() {
  step "1  워크로드 클러스터(6단계 삭제와 OpenStack 정리 확인)"  p_cluster  d_cluster
  step "2  Terraform 자원 destroy 와 이름·ID 삭제 확인"          p_tfd      d_tfd
  step "3  kind 관리 클러스터"                                    p_kind     d_kind
  step "4  OpenStack(Kolla) 컨테이너·볼륨"                        p_kolla    d_kolla
  step "5  Terraform 디렉터리(상태 파일)"                         p_tf       d_tf
  step "6  노드 이미지 빌드 산출물"                                p_image    d_image
  step "7  노드 SSH 키"                                            p_key      d_key
  step "8  ~/capi(주문서, kubeconfig, 기록)"                       p_capi     d_capi
  step "9  /etc/kolla 와 인벤토리"                                 p_kcfg     d_kcfg
  step "10 Kolla 가상환경"                                         p_venv     d_venv
  step "11 도구 4종(kubectl, terraform, kind, clusterctl)"         p_tools    d_tools
  step "12 호스트 네트워크(kolla0, veth, 규칙, 유닛)"              p_hostnet  d_hostnet
  step "13 Docker(--with-docker 일 때만)"                         p_docker   d_docker
}

# ----------------------------------------------------------------- 실행 전 안전 점검
guard() {
  local d
  d="$(ls -d "$HOME"/backup-*/ 2>/dev/null | tail -n1 || true)"
  [[ -n "$d" && -s "${d}SHA256SUMS.txt" ]] || die "백업 폴더(~/backup-*/SHA256SUMS.txt)를 찾지 못했습니다. 백업을 먼저 만드세요." "$EXIT_FAIL"
  ( cd "$d" && sha256sum -c --quiet SHA256SUMS.txt ) || die "백업 해시가 맞지 않습니다: $d" "$EXIT_FAIL"
  log_info "백업 확인: ${d} (해시 일치). PC 에 사본이 있는지는 직접 확인하세요."
  [[ -n "${TMUX:-}" ]] || die "tmux 안에서 실행하세요. SSH 가 끊겨도 정리가 계속되도록 하기 위한 조건입니다(예: tmux new -s reset)." "$EXIT_USAGE"
  ip link show "$HOST_NIC" >/dev/null 2>&1 || die "물리 NIC(${HOST_NIC})를 찾지 못했습니다. HOST_NIC 값을 확인하세요." "$EXIT_FAIL"
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    local sip; sip="$(awk '{print $3}' <<<"$SSH_CONNECTION")"
    ip -4 -o addr show dev "$HOST_NIC" 2>/dev/null | grep -qF " ${sip}/" \
      || die "이 SSH 접속의 서버 쪽 주소가 ${HOST_NIC} 에 없습니다. ${KOLLA_NET_IF}/${EXT_HOST_IF} 쪽 주소로 들어온 접속이면 정리 중 끊길 수 있어 중단합니다." "$EXIT_FAIL"
  else
    log_warn "SSH_CONNECTION 이 없어 접속 경로를 확인하지 못했습니다(콘솔이거나 tmux 안일 수 있음)."
  fi
  if have_cmd docker && ! dk ps >/dev/null 2>&1; then die "docker 에 접근할 수 없습니다. 재로그인(docker 그룹 적용) 후 다시 실행하세요." "$EXIT_FAIL"; fi
  sudo -v || die "sudo 권한을 얻지 못했습니다." "$EXIT_FAIL"
}
confirm_reset() {
  local hn; hn="$(hostname)"
  log_warn "전체 초기화: 워크로드 클러스터, Terraform 자원, kind, OpenStack(Kolla) 컨테이너·볼륨, /etc/kolla, 키트 도구, 호스트 네트워크 설정$([[ "$WITH_DOCKER" == "1" ]] && echo ', Docker')까지 지웁니다. 되돌릴 수 없습니다."
  log_info "보존: 물리 NIC 설정, ~/backup-*, ~/kit*, history, authorized_keys, 호스트 이름, 일반 apt 패키지, 기존 libvirt 네트워크·풀·디스크(참고만 함)."
  log_info "복구: 'make up' 으로 0~5단계를 다시 구축합니다(이미지 빌드 포함 시 오래 걸림)."
  if [[ "${KIT_CONFIRM_RESET:-}" == "$hn" ]]; then log_info "KIT_CONFIRM_RESET 이 호스트 이름과 같으므로 진행합니다."; return 0; fi
  [[ -t 0 ]] || die "확인이 필요하지만 터미널이 아닙니다. 터미널에서 실행하거나 KIT_CONFIRM_RESET=${hn} 로 명시하세요(--yes 로는 건너뛸 수 없습니다)." "$EXIT_USAGE"
  local ans; read -r -p "초기화하려면 이 서버의 호스트 이름(${hn})을 그대로 입력하세요: " ans
  [[ "$ans" == "$hn" ]] || die "입력이 일치하지 않아 초기화하지 않았습니다." "$EXIT_FAIL"
}

log_info "초기화 $([[ "$EXECUTE" == "1" ]] && echo '실행' || echo '계획(dry-run)')을 시작합니다 (로그: $KIT_LOG_FILE)"
if have_cmd docker && ! dk ps >/dev/null 2>&1; then log_warn "docker 에 접근할 수 없습니다(재로그인 필요?). kind 와 Kolla 대상이 '없음'으로 보일 수 있습니다."; fi
show_targets
if [[ "$EXECUTE" == "1" ]]; then
  guard
  EXECUTE=0; run_all; EXECUTE=1
  [[ "$PLANNED" -gt 0 ]] || { log_done "지울 것이 없습니다."; exit "$EXIT_OK"; }
  confirm_reset
  PLANNED=0
else
  run_all
fi
[[ "$EXECUTE" == "1" ]] && run_all

if [[ -d /var/lib/kolla ]]; then log_warn "/var/lib/kolla 가 남아 있습니다($(sudo -n du -sh /var/lib/kolla 2>/dev/null | cut -f1)). 이 스크립트는 지우지 않습니다. 재배포에 영향이 있는지 확인이 필요합니다."; fi
active=""; for u in libvirtd.service libvirtd.socket virtlogd.service virtlogd.socket virtlockd.service virtlockd.socket; do systemctl is-active --quiet "$u" 2>/dev/null && active+="$u "; done
[[ -z "$active" ]] && log_info "호스트 libvirt 계열은 중지 상태로 남깁니다(1단계의 '호스트 libvirt 중지' 단계는 SKIP 되므로 이 변경 경로는 시험되지 않습니다)." || log_warn "호스트 libvirt 계열이 활성: ${active}"

if [[ "$EXECUTE" == "1" ]]; then
  log_done "초기화 실행 종료. 남은 인터페이스: $(ip -br link | awk '{print $1}' | tr '\n' ' ')"
  log_info "깨끗한 상태 확인(stage0/check-clean-state.sh)을 실행합니다. libvirt 의 기존 네트워크·풀은 이 스크립트가 지우지 않아 FAIL 로 남을 수 있습니다."
  bash "$KIT_ROOT/stage0/check-clean-state.sh" || log_warn "깨끗한 상태 확인에 FAIL 이 있습니다. 위 항목을 확인하세요."
  log_info "다음: docker 그룹을 뺐다면 로그아웃 후 다시 접속하고, 'make up' 을 실행하세요."
else
  log_info "(계획만 출력했습니다) 지울 단계 ${PLANNED}개. 실제로 지우려면: bash scripts/reset-lab.sh --execute [--with-docker] [--keep-node-image]"
fi
