#!/usr/bin/env bash
# stage2/apply.sh — 2단계: Kubernetes 노드 이미지를 빌드하고, Terraform 으로 공용 자원을 만든다.
#
#   --dry-run  변경 없이 실행 계획만 출력 (이미 구축된 서버에서는 전부 SKIP 이어야 한다)
#   --yes      호스트 변경 확인 질문 없이 진행
#
# 순서: packages -> kvm_acl -> ib_clone -> ib_venv -> ib_deps -> ib_vars -> image_build -> keypair -> tf_files -> tf_apply
#
# 수동 구축에서 얻은 규칙
#  - image-builder 의존성은 Kolla 가상환경과 분리된 ~/ib-venv 에 설치한다(ansible-core 충돌 방지).
#    그래서 이 스크립트는 kolla-venv 를 PATH 에 올리지 않고, 빌드는 깨끗한 PATH 로 실행한다.
#  - /dev/kvm 은 Kolla 가 그룹을 바꿔 일반 사용자가 못 쓴다. 그룹 소유자는 그대로 두고 ACL 로 사용자만 허용한다(재부팅이나 장치 재생성 시 사라질 수 있음).
#  - 이미지 빌드는 약 31분이다. SSH 가 끊겨도 계속되도록 tmux 안에서 실행해야 한다.
#  - terraform apply 는 승인 질문이 없게(-input=false -auto-approve) 하고, 실행 전 plan 을 로그에 남긴다. 출력을 파이프로 가리지 않는다.
#  - 이미 있는 main.tf 는 덮어쓰지 않는다(FORCE_OVERWRITE_TF=1 일 때만 백업 후 교체).
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/common.sh"
kit_parse_args "$@"
kit_init stage2 apply

HERE="$KIT_ROOT/stage2"
IB_CAPI="$IB_DIR/images/capi"
IB_VARS_FILE="$IB_VARS_DIR/k8s136.json"
OPENRC="$KOLLA_CONFIG_DIR/admin-openrc.sh"
OSC="$KOLLA_VENV/bin/openstack"
CLEAN_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"   # kolla-venv 를 제외한 PATH

kit_diagnose() {
  local t; t="$(tail -n 400 "$1" 2>/dev/null || true)"
  grep -qiE "Could not access KVM|Permission denied.*/dev/kvm|/dev/kvm" <<<"$t" \
    && hint "/dev/kvm 접근 불가" "sudo setfacl -m u:$(id -un):rw /dev/kvm (재부팅이나 장치 재생성 시 사라질 수 있다)"
  grep -qE "Enter a value:|Do you want to perform these actions" <<<"$t" \
    && hint "terraform 승인 질문 대기" "-input=false -auto-approve 로 실행하고 출력을 파이프로 가리지 않는다"
  grep -qE "No such file or directory.*(k8s-node-key|ubuntu-2404-kube)" <<<"$t" \
    && hint "Terraform 입력 파일 없음" "키페어(~/.ssh/k8s-node-key.pub)와 이미지 파일이 먼저 만들어져야 한다"
  grep -q "Error acquiring the state lock" <<<"$t" \
    && hint "Terraform 상태 잠금" "다른 terraform 프로세스가 없는지 확인한 뒤 잠금 해제"
  return 0
}

load_openrc() {   # 값은 출력하지 않는다. 자격 증명은 환경변수에만 둔다.
  [[ -r "$OPENRC" ]] || die "$OPENRC 를 읽을 수 없습니다. 1단계(post-deploy)가 끝났는지 확인하세요." "$EXIT_FAIL"
  set +u
  # shellcheck disable=SC1090
  source "$OPENRC"
  set -u
}

in_tmux() { [[ -n "${TMUX:-}" || -n "${STY:-}" ]]; }
kvm_ok()  { [[ -r /dev/kvm && -w /dev/kvm ]]; }
tf()      { ( cd "$TF_COMMON_DIR" && terraform "$@" ); }

glance_image_active() {
  local cfg="$KOLLA_CONFIG_DIR/clouds.yaml"
  [[ -x "$OSC" && -r "$cfg" ]] || return 1
  OS_CLIENT_CONFIG_FILE="$cfg" timeout 60 "$OSC" --os-cloud "$KOLLA_CLOUD" image show "$NODE_IMAGE_NAME" -f value -c status 2>/dev/null | grep -qx active
}
image_file_ok() {
  [[ -f "$NODE_IMAGE_FILE" ]] || return 1
  have_cmd qemu-img || return 0
  qemu-img info "$NODE_IMAGE_FILE" 2>/dev/null | grep -q 'file format: qcow2'
}

render_ib_vars() {
  printf '{\n  "kubernetes_series": "%s",\n  "kubernetes_semver": "%s",\n  "kubernetes_deb_version": "%s",\n  "cpus": "%s",\n  "memory": "%s"\n}\n' \
    "$K8S_SERIES" "$K8S_SEMVER" "$K8S_DEB_VERSION" "$IB_CPUS" "$IB_MEMORY"
}

# ------------------------------------------------------------------ 단계 정의
STEPS=(packages kvm_acl ib_clone ib_venv ib_deps ib_vars image_build keypair tf_files tf_apply)
declare -A TITLE=(
  [packages]="빌드 도구 패키지(make, qemu-system-x86, qemu-utils, git, python3-venv, unzip)"
  [kvm_acl]="/dev/kvm 접근 허용(ACL)"
  [ib_clone]="image-builder 저장소(커밋 ${IB_COMMIT})"
  [ib_venv]="image-builder 전용 가상환경 ${IB_VENV}"
  [ib_deps]="image-builder 의존성(make deps-qemu: Packer, 플러그인, ansible-core)"
  [ib_vars]="빌드 변수 파일(Kubernetes ${K8S_SEMVER})"
  [image_build]="노드 이미지 빌드(${NODE_IMAGE_NAME}, 약 31분)"
  [keypair]="SSH 키 ${NODE_KEY}"
  [tf_files]="Terraform 작업 디렉터리 ${TF_COMMON_DIR}"
  [tf_apply]="Terraform 공용 자원(init, plan, apply: ${TF_RESOURCE_COUNT}개)"
)
REASON=""
PKG_TODO=()
declare -A PKG_FOR=([make]=make [qemu-system-x86_64]=qemu-system-x86 [qemu-img]=qemu-utils [git]=git [unzip]=unzip)

need_packages() {
  PKG_TODO=(); local c
  for c in "${!PKG_FOR[@]}"; do have_cmd "$c" || PKG_TODO+=("${PKG_FOR[$c]}"); done
  python3 -c 'import venv, ensurepip' >/dev/null 2>&1 || PKG_TODO+=(python3-venv)
  if [[ "${#PKG_TODO[@]}" -gt 0 ]]; then REASON="없음: ${PKG_TODO[*]}"; return 0; fi
  REASON="필요한 명령이 모두 있음"; return 1
}
do_packages() {
  run_step "apt 패키지 설치" sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKG_TODO[@]}"
}

need_kvm_acl() {
  # /dev/kvm 은 이미지 빌드(사용자 프로세스의 qemu)에만 필요하다. 노드 VM 은 nova_libvirt 컨테이너가 실행한다.
  # ACL 은 VM 을 지울 때 사라지는 것으로 보여(관찰, 원인 미확인) 이미지가 이미 있으면 건드리지 않는다.
  if glance_image_active || image_file_ok; then REASON="노드 이미지가 이미 있어 사용자 KVM 접근이 필요 없음(빌드할 때만 필요)"; return 1; fi
  if kvm_ok; then REASON="$(id -un) 이(가) /dev/kvm 읽기·쓰기 가능"; return 1; fi
  if [[ ! -e /dev/kvm ]]; then REASON="/dev/kvm 없음(하드웨어 가상화 비활성). ACL 로 해결할 수 없음"; return 0; fi
  REASON="/dev/kvm 접근 불가($(stat -c '%A %U:%G' /dev/kvm))"; return 0
}
do_kvm_acl() {
  [[ -e /dev/kvm ]] || die "/dev/kvm 이 없습니다. BIOS 의 가상화 설정과 'systemd-detect-virt' 결과를 확인하세요." "$EXIT_FAIL"
  have_cmd setfacl || run_step "acl 패키지 설치" sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y acl
  run_step "/dev/kvm ACL 추가" sudo setfacl -m "u:$(id -un):rw" /dev/kvm
  kvm_ok || die "ACL 을 추가했지만 /dev/kvm 을 여전히 쓸 수 없습니다." "$EXIT_FAIL"
  log_warn "이 ACL 은 재부팅이나 장치 재생성으로 사라질 수 있습니다. 사라지면 'bash stage2/apply.sh' 를 다시 실행하세요."
}

need_ib_clone() {
  if [[ ! -d "$IB_DIR/.git" ]]; then REASON="$IB_DIR 없음"; return 0; fi
  local cur; cur="$(git -C "$IB_DIR" rev-parse --short=12 HEAD 2>/dev/null || true)"
  if [[ "$cur" == "$IB_COMMIT" ]]; then REASON="커밋 $cur 와 일치"; return 1; fi
  REASON="현재 커밋 ${cur:-불명} != ${IB_COMMIT}"; return 0
}
do_ib_clone() {
  [[ -d "$IB_DIR/.git" ]] || run_step "image-builder clone" git clone "$IB_REPO" "$IB_DIR"
  run_step "커밋 ${IB_COMMIT} 로 고정" git -C "$IB_DIR" -c advice.detachedHead=false checkout "$IB_COMMIT"
}

need_ib_venv() {
  if [[ -x "$IB_VENV/bin/python" ]]; then REASON="$IB_VENV 있음"; return 1; fi
  REASON="$IB_VENV 없음"; return 0
}
do_ib_venv() { run_step "ib-venv 생성" python3 -m venv "$IB_VENV"; }

ib_ansible_version() { "$IB_VENV/bin/python" -m pip show ansible-core 2>/dev/null | awk '/^Version:/{print $2}' || true; }
ib_packer_version()  { "$IB_CAPI/.local/bin/packer" version 2>/dev/null | head -n1 | sed 's/^Packer v//' || true; }

need_ib_deps() {
  if image_file_ok && [[ ! -x "$IB_CAPI/.local/bin/packer" ]]; then REASON="이미지 파일이 이미 있어 의존성이 필요 없음"; return 1; fi
  local a p; a="$(ib_ansible_version)"; p="$(ib_packer_version)"
  if [[ "$a" == "$IB_ANSIBLE_CORE" && "$p" == "$IB_PACKER" ]]; then REASON="ansible-core $a, Packer $p"; return 1; fi
  if glance_image_active || image_file_ok; then REASON="이미지가 이미 있어 의존성이 필요 없음(ansible-core ${a:-없음}, Packer ${p:-없음})"; return 1; fi
  REASON="ansible-core ${a:-없음}(기대 $IB_ANSIBLE_CORE), Packer ${p:-없음}(기대 $IB_PACKER)"; return 0
}
do_ib_deps() {
  # kolla-venv 를 빼고, ib-venv 를 활성화한 PATH 로 실행한다.
  run_step "make deps-qemu" env -u VIRTUAL_ENV PATH="$IB_VENV/bin:$CLEAN_PATH" VIRTUAL_ENV="$IB_VENV" \
    bash -c "cd '$IB_CAPI' && make deps-qemu"
}

need_ib_vars() {
  if [[ -f "$IB_VARS_FILE" ]] && diff -q <(render_ib_vars) "$IB_VARS_FILE" >/dev/null 2>&1; then REASON="$IB_VARS_FILE 내용 일치"; return 1; fi
  REASON="$IB_VARS_FILE 없음 또는 versions.env 와 다름"; return 0
}
do_ib_vars() {
  mkdir -p "$IB_VARS_DIR"
  [[ -f "$IB_VARS_FILE" ]] && cp -n "$IB_VARS_FILE" "${IB_VARS_FILE}.bak-kit"
  render_ib_vars >"$IB_VARS_FILE"
  log_info "작성: $IB_VARS_FILE"
}

need_image_build() {
  if glance_image_active; then REASON="Glance 에 '$NODE_IMAGE_NAME' 이미지가 active"; return 1; fi
  if image_file_ok; then REASON="이미지 파일이 이미 있음($NODE_IMAGE_FILE). 빌드하지 않고 Terraform 이 등록"; return 1; fi
  REASON="이미지 파일 없음, Glance 에도 없음"; return 0
}
do_image_build() {
  if ! in_tmux && [[ "${KIT_ALLOW_NO_TMUX:-0}" != "1" ]]; then
    die "이미지 빌드는 약 31분이 걸립니다. tmux 안에서 실행하세요(예: 'tmux new -s kit' 후 다시 실행). 감수하려면 KIT_ALLOW_NO_TMUX=1" "$EXIT_FAIL"
  fi
  kvm_ok || die "/dev/kvm 접근이 불가합니다. 먼저 kvm_acl 단계를 실행하세요." "$EXIT_FAIL"
  run_step "make build-qemu-ubuntu-2404 (약 31분)" env -u VIRTUAL_ENV PATH="$IB_VENV/bin:$CLEAN_PATH" VIRTUAL_ENV="$IB_VENV" \
    bash -c "cd '$IB_CAPI' && make build-qemu-ubuntu-2404 PACKER_VAR_FILES='$IB_VARS_FILE'"
  image_file_ok || die "빌드가 끝났지만 이미지 파일이 없거나 qcow2 가 아닙니다: $NODE_IMAGE_FILE" "$EXIT_FAIL"
}

need_keypair() {
  if [[ -f "$NODE_KEY" && -f "$NODE_KEY.pub" ]]; then REASON="키 쌍 있음"; return 1; fi
  REASON="키 쌍 없음"; return 0
}
do_keypair() {
  [[ -e "$NODE_KEY" ]] && die "$NODE_KEY 는 있지만 .pub 이 없습니다. 덮어쓰지 않습니다. 'ssh-keygen -y -f $NODE_KEY > $NODE_KEY.pub' 로 복원하세요." "$EXIT_FAIL"
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  run_step "SSH 키 생성" ssh-keygen -t ed25519 -N '' -C k8s-node -f "$NODE_KEY"
}

need_tf_files() {
  local miss=()
  [[ -f "$TF_COMMON_DIR/main.tf" ]] || miss+=("main.tf 없음")
  if [[ -f "$TF_COMMON_DIR/main.tf" ]] && ! diff -q "$HERE/terraform/main.tf" "$TF_COMMON_DIR/main.tf" >/dev/null 2>&1; then
    if [[ "$FORCE_OVERWRITE_TF" == "1" ]]; then miss+=("main.tf 가 키트 것과 다름(교체 예정)")
    else check_warn "main.tf 가 키트와 다름" "덮어쓰지 않는다. 교체하려면 FORCE_OVERWRITE_TF=1 (diff $HERE/terraform/main.tf $TF_COMMON_DIR/main.tf)"; fi
  fi
  [[ -f "$TF_COMMON_DIR/.gitignore" ]] || miss+=(".gitignore 없음")
  if [[ "${#miss[@]}" -gt 0 ]]; then REASON="${miss[*]}"; return 0; fi
  REASON="main.tf, .gitignore 있음"; return 1
}
do_tf_files() {
  mkdir -p "$TF_COMMON_DIR"
  if [[ ! -f "$TF_COMMON_DIR/main.tf" ]]; then
    run_step "main.tf 복사" cp "$HERE/terraform/main.tf" "$TF_COMMON_DIR/main.tf"
  elif [[ "$FORCE_OVERWRITE_TF" == "1" ]] && ! diff -q "$HERE/terraform/main.tf" "$TF_COMMON_DIR/main.tf" >/dev/null 2>&1; then
    run_step "main.tf 백업" cp -n "$TF_COMMON_DIR/main.tf" "$TF_COMMON_DIR/main.tf.bak-kit"
    run_step "main.tf 교체" cp "$HERE/terraform/main.tf" "$TF_COMMON_DIR/main.tf"
  fi
  [[ -f "$TF_COMMON_DIR/.gitignore" ]] || printf '*.tfstate*\n.terraform/\n' >"$TF_COMMON_DIR/.gitignore"
}

need_tf_apply() {
  if [[ ! -d "$TF_COMMON_DIR/.terraform" || ! -f "$TF_COMMON_DIR/main.tf" ]]; then REASON="terraform init 필요"; return 0; fi
  if [[ ! -r "$OPENRC" ]]; then REASON="$OPENRC 없음, 계획 불가(1단계 필요)"; return 0; fi
  local rc=0
  ( load_openrc; cd "$TF_COMMON_DIR" && terraform plan -input=false -lock=false -detailed-exitcode >/dev/null 2>&1 ) || rc=$?
  case "$rc" in
    0) REASON="terraform plan: 변경 없음"; return 1 ;;
    2) REASON="terraform plan: 변경 있음(적용 필요)"; return 0 ;;
    *) REASON="terraform plan 실패(rc=$rc). 앞 단계(키 쌍, 이미지 파일)가 선행되어야 할 수 있음"; return 0 ;;
  esac
}
do_tf_apply() {
  # 같은 PATH 에 kolla-venv 가 없어도 terraform 은 동작한다.
  load_openrc
  [[ -f "$NODE_KEY.pub" ]]  || die "$NODE_KEY.pub 가 없습니다." "$EXIT_FAIL"
  [[ -f "$NODE_IMAGE_FILE" ]] || die "노드 이미지 파일이 없습니다: $NODE_IMAGE_FILE" "$EXIT_FAIL"
  run_step "terraform init" bash -c "cd '$TF_COMMON_DIR' && terraform init -input=false"
  run_step "terraform plan (로그에 남김)" bash -c "cd '$TF_COMMON_DIR' && terraform plan -input=false"
  run_step "terraform apply" bash -c "cd '$TF_COMMON_DIR' && terraform apply -input=false -auto-approve"
}

# ------------------------------------------------------------------ 계획 수립
log_info "2단계 계획을 세웁니다 (로그: $KIT_LOG_FILE)"
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
  sudo_nopass || die "sudo 를 비밀번호 없이 쓸 수 없습니다. 'sudo -n true' 가 성공해야 합니다." "$EXIT_FAIL"
  if [[ " ${PLAN[*]} " == *" image_build "* ]] && ! in_tmux && [[ "${KIT_ALLOW_NO_TMUX:-0}" != "1" ]]; then
    die "이미지 빌드(약 31분)가 계획에 있습니다. tmux 안에서 실행하세요(예: 'tmux new -s kit'). 감수하려면 KIT_ALLOW_NO_TMUX=1" "$EXIT_FAIL"
  fi
  impact="${#PLAN[@]}개 단계 실행:"
  [[ " ${PLAN[*]} " == *" packages "* ]]    && impact+=" apt 패키지 설치;"
  [[ " ${PLAN[*]} " == *" kvm_acl "* ]]     && impact+=" /dev/kvm 에 사용자 ACL 추가(그룹 소유자는 그대로, 재부팅이나 장치 재생성 시 사라질 수 있음);"
  [[ " ${PLAN[*]} " == *" image_build "* ]] && impact+=" 노드 이미지 빌드(약 31분, CPU 4, 메모리 4GiB, 디스크 약 8GiB 사용);"
  [[ " ${PLAN[*]} " == *" tf_apply "* ]]    && impact+=" OpenStack 에 네트워크, 라우터, flavor, 키페어, 이미지 생성;"
  confirm "$impact" "Terraform 자원: 'cd $TF_COMMON_DIR && terraform destroy'. /dev/kvm ACL: 'sudo setfacl -x u:$(id -un) /dev/kvm'. 그 외는 만든 폴더 삭제"
fi

for id in "${PLAN[@]}"; do
  log_step "== ${TITLE[$id]}"
  "do_$id"
done

report_summary || true
log_done "2단계 실행 완료"
