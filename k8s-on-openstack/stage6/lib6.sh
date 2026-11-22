#!/usr/bin/env bash
# stage6 공용 함수. source 해서 쓴다. common.sh 와 versions.env 를 먼저 불러온 상태여야 한다.
KUBECTL="$BIN_DIR/kubectl"; OSC="$KOLLA_VENV/bin/openstack"; CFG="$KOLLA_CONFIG_DIR/clouds.yaml"
mkc() { env -u KUBECONFIG "$KUBECTL" --context "$KUBE_CONTEXT" "$@"; }     # 관리 클러스터. 워크로드 KUBECONFIG 가 설정돼 있어도 영향 없음
os()  { OS_CLIENT_CONFIG_FILE="$CFG" timeout 120 "$OSC" --os-cloud "$KOLLA_CLOUD" "$@"; }
SNAP_KINDS=(server:"server list" floating_ip:"floating ip list" security_group:"security group list" port:"port list" volume:"volume list" network:"network list" subnet:"subnet list" router:"router list" keypair:"keypair list" flavor:"flavor list" image:"image list")

# snapshot <dir> [capo|nocapo]   OpenStack 상태를 JSON 으로 기록한다. 비밀은 포함되지 않는다.
snapshot() {
  local dir="$1" mode="${2:-nocapo}" ent k cmd
  mkdir -p "$dir"
  for ent in "${SNAP_KINDS[@]}"; do
    k="${ent%%:*}"; cmd="${ent#*:}"
    # shellcheck disable=SC2086
    if ! os $cmd -f json >"$dir/$k.json.tmp" 2>"$dir/$k.err"; then
      # Cinder 를 설치하지 않은 환경에서는 volume 서비스가 카탈로그에 없다. 볼륨이 없는 것으로 기록한다(노드는 이미지 기반 로컬 디스크).
      if [[ "$k" == "volume" ]] && grep -qiE "block-storage|volumev3|not present in the service catalog|endpoint for .* not found" "$dir/$k.err"; then
        echo "[]" >"$dir/$k.json.tmp"; echo "볼륨 서비스(Cinder)가 없어 볼륨 0개로 기록합니다." >&2
      else
        rm -f "$dir/$k.json.tmp"; echo "조회 실패: openstack $cmd ($(head -c 200 "$dir/$k.err"))" >&2; return 1
      fi
    fi
    mv "$dir/$k.json.tmp" "$dir/$k.json"; rm -f "$dir/$k.err"
  done
  if [[ "$mode" == "capo" ]]; then
    local ids sid; ids="$(python3 -c '
import sys, json
for r in json.load(open(sys.argv[1])):
    if r.get("Name","").startswith(sys.argv[2] + "-"): print(r["ID"])' "$dir/server.json" "$CLUSTER_NAME")"
    local ports_file
    ports_file="$(mktemp)" || return 1

    for sid in $ids; do
      if ! os port list --device-id "$sid" -f json -c ID >>"$ports_file"; then
        rm -f -- "$ports_file"
        echo "[ERROR] CAPO 서버 포트 조회 실패: $sid" >&2
        return 1
      fi
    done

    python3 -c '
import sys, json
dec = json.JSONDecoder(); s = open(sys.argv[1]).read().strip(); out = []; i = 0
while i < len(s):
    while i < len(s) and s[i].isspace(): i += 1
    if i >= len(s): break
    v, i = dec.raw_decode(s, i); out += [r["ID"] for r in v]
print(json.dumps(out))' "$ports_file" >"$dir/capo_ports.json" || {
      rm -f -- "$ports_file"
      return 1
    }
    rm -f -- "$ports_file"
    if ! mkc -n default get cluster "$CLUSTER_NAME" -o jsonpath='{.spec.controlPlaneEndpoint.host}' >"$dir/api_fip.txt"; then
      echo "[ERROR] CAPO 클러스터 API Floating IP 조회 실패" >&2
      return 1
    fi

    if [[ ! -s "$dir/api_fip.txt" ]]; then
      echo "[ERROR] CAPO 클러스터 API Floating IP 주소가 비어 있습니다" >&2
      return 1
    fi
  fi
  date -Is >"$dir/taken-at.txt"
}

# owned_left   삭제 대상(서버, 클러스터 SG, API Floating IP)이 아직 OpenStack 에 남아 있으면 목록을 출력한다.
owned_left() {
  local fip="$1" out="" srv sg fips ports_file port_ids current_ports

  srv="$(os server list -f value -c Name 2>/dev/null)" ||
    { printf '%s' "조회실패(server)"; return 0; }

  sg="$(os security group list -f value -c Name 2>/dev/null)" ||
    { printf '%s' "조회실패(security group)"; return 0; }

  out+="$(grep "^${CLUSTER_NAME}-" <<<"$srv" | tr '\n' ' ' || true)"
  out+="$(grep -E "^k8s-cluster-.*-${CLUSTER_NAME}-secgroup-" <<<"$sg" | tr '\n' ' ' || true)"

  if [[ -n "$fip" ]]; then
    fips="$(os floating ip list -f value -c "Floating IP Address" 2>/dev/null)" ||
      { printf '%s' "조회실패(floating ip)"; return 0; }

    out+="$(grep -Fx "$fip" <<<"$fips" | tr '\n' ' ' || true)"
  fi

  ports_file="$BEFORE/capo_ports.json"
  if [[ ! -s "$ports_file" ]]; then
    printf '%s' "조회실패(CAPO 포트 기록 없음)"
    return 0
  fi

  port_ids="$(python3 - "$ports_file" <<'PYPORT'
import json
import sys

try:
    with open(sys.argv[1]) as f:
        ids = json.load(f)
    if not isinstance(ids, list) or not ids:
        raise ValueError("CAPO 포트 목록이 비어 있거나 배열이 아님")
    if any(not isinstance(x, str) or not x for x in ids):
        raise ValueError("포트 ID 형식 오류")
    print("\n".join(ids))
except (OSError, ValueError, TypeError):
    raise SystemExit(1)
PYPORT
)" || { printf '%s' "조회실패(CAPO 포트 기록 오류)"; return 0; }

  current_ports="$(os port list -f value -c ID 2>/dev/null)" ||
    { printf '%s' "조회실패(port)"; return 0; }

  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if grep -qxF "$id" <<<"$current_ports"; then
      out+="CAPO-port-${id:0:8} "
    fi
  done <<<"$port_ids"

  printf '%s' "$out"
}

# report_compare <before_dir> <after_dir>   compare.py 의 출력을 check_ok/check_ng/check_warn 으로 옮긴다.
report_compare() {
  local lvl title want got why
  local result_file
  result_file="$(mktemp)" || return 1

  if ! python3 -I "$KIT_ROOT/stage6/compare.py" "$1" "$2" "$CLUSTER_NAME" >"$result_file"; then
    cat "$result_file"
    rm -f -- "$result_file"
    echo "[ERROR] OpenStack 삭제 전후 비교 실패" >&2
    return 1
  fi

  while IFS=$'\t' read -r lvl title want got why; do
    case "$lvl" in
      OK) check_ok "$title" ;;
      NG) check_ng "$title" "$want" "$got" "$why" ;;
      WARN) check_warn "$title" "${got:-$want}" ;;
      *) rm -f -- "$result_file"; echo "[ERROR] 알 수 없는 비교 결과: $lvl" >&2; return 1 ;;
    esac
  done <"$result_file"

  rm -f -- "$result_file"
}
