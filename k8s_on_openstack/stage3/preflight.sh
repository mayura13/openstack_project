#!/usr/bin/env bash
# stage3/preflight.sh — 3단계 실행 전 점검. 읽기 전용.
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage3 preflight
log_info "3단계 사전 점검을 시작합니다 (로그: $KIT_LOG_FILE)"

[[ "$(id -u)" -ne 0 ]] && check_ok "root 가 아닌 일반 계정" || check_ng "root 가 아닌 일반 계정" "일반 계정" "root" "kubeconfig 소유권이 어긋난다"
sudo_nopass && check_ok "sudo 비밀번호 없이 사용" || check_ng "sudo 비밀번호 없이 사용" "sudo -n true 성공" "실패" "방화벽 규칙 추가에 필요"

# 0단계 도구
for t in kubectl:"$KUBECTL_VERSION" kind:"$KIND_VERSION" clusterctl:"$CLUSTERCTL_VERSION"; do
  name="${t%%:*}"; want="${t#*:}"; cur="$(tool_version "$name")"
  [[ "$cur" == "$want" ]] && check_ok "$name 버전" "$cur" || check_ng "$name 버전" "$want" "${cur:-없음}" "0단계 install 실행"
done

# Docker
if have_cmd docker && docker ps >/dev/null 2>&1; then check_ok "docker 를 sudo 없이 사용"
elif user_in_group_db docker; then check_ng "docker 를 sudo 없이 사용" "docker ps 성공" "그룹은 있으나 세션에 미적용" "새로 로그인(tmux 서버도 재시작). apply.sh 는 종료 코드 2 로 안내한다"
else check_ng "docker 를 sudo 없이 사용" "docker ps 성공" "실패" "1단계 apply 로 docker 설치와 그룹 추가"; fi
if grep -qE '"iptables"[[:space:]]*:[[:space:]]*false' /etc/docker/daemon.json 2>/dev/null; then
  check_ok "Docker iptables:false 확인" "kind 대역 NAT 를 키트가 대신 만든다"
else
  check_warn "daemon.json 에 iptables:false 가 없음" "Docker 가 NAT 를 만들 수 있다. 중복 규칙은 무해하지만 1단계 구성과 다르다"
fi

# 호스트 네트워크
[[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)" == "1" ]] && check_ok "net.ipv4.ip_forward=1" || check_ng "net.ipv4.ip_forward=1" "1" "아님" "1단계 host_net 적용"
if [[ -f "$HOST_NET_SCRIPT" ]]; then check_ok "호스트 네트워크 스크립트" "$HOST_NET_SCRIPT"
else check_ng "호스트 네트워크 스크립트" "$HOST_NET_SCRIPT" "없음" "1단계 host_net 단계"; fi
ip link show "$EXT_HOST_IF" >/dev/null 2>&1 && check_ok "$EXT_HOST_IF 인터페이스" || check_ng "$EXT_HOST_IF 인터페이스" "있음" "없음" "1단계 host_net 적용"

# 앞 단계
code="$(http_code "http://${KOLLA_VIP}:5000/v3")"
[[ "$code" == "200" ]] && check_ok "OpenStack Keystone 응답" "HTTP $code" || check_ng "OpenStack Keystone 응답" "HTTP 200" "HTTP ${code:-없음}" "1단계 postcheck 를 먼저 통과시킨다"
OSC="$KOLLA_VENV/bin/openstack"; CFG="$KOLLA_CONFIG_DIR/clouds.yaml"
nimg="$(OS_CLIENT_CONFIG_FILE="$CFG" timeout 60 "$OSC" --os-cloud "$KOLLA_CLOUD" image show "$NODE_IMAGE_NAME" -f value -c status 2>/dev/null || true)"
[[ "$nimg" == "active" ]] && check_ok "노드 이미지 active(2단계)" "$NODE_IMAGE_NAME" || check_ng "노드 이미지 active(2단계)" "active" "${nimg:-없음}" "2단계 apply 실행"

# 호스트의 인터넷(이미지, 매니페스트)
for u in $KIND_REGISTRIES https://github.com/kubernetes-sigs/cluster-api/releases https://kind.sigs.k8s.io/; do
  c="$(http_code "$u")"
  [[ "$c" =~ ^(200|301|302|401)$ ]] && check_ok "접속: ${u#https://}" "HTTP $c" || check_ng "접속: ${u#https://}" "응답 있음" "HTTP ${c:-없음}" "방화벽, DNS, 프록시 확인"
done

# 기존 상태 안내
if have_cmd kind && docker ps >/dev/null 2>&1 && "$BIN_DIR/kind" get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
  check_warn "관리 클러스터 $KIND_CLUSTER 가 이미 있음" "apply.sh 는 만들지 않고 provider 와 파드 상태만 확인한다"
fi
if [[ -f "$HOME/.kube/config" ]]; then
  ctxs="$("$BIN_DIR/kubectl" config get-contexts -o name 2>/dev/null | grep -vx "$KUBE_CONTEXT" | tr '\n' ' ' || true)"
  [[ -z "${ctxs// }" ]] || check_warn "\$HOME/.kube/config 에 다른 컨텍스트 있음: ${ctxs}" "키트는 항상 --context $KUBE_CONTEXT 를 명시하고 기존 항목은 지우지 않는다"
fi

report_summary || die "점검 실패. 위 [FAIL] 항목을 해결한 뒤 다시 실행하세요." "$EXIT_FAIL"
log_done "3단계 사전 점검 통과"
