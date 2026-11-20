#!/usr/bin/env bash
# ==============================================================
# generate-inventory.sh - Terraform이 만든 VM 정보를 Ansible 인벤토리 파일로 바꿔 주는 연결 고리
# ==============================================================
# 인벤토리(inventory) = "어떤 서버들이 있고, 어떤 주소로 접속하는지" 적은 목록 파일입니다.
# 1단계(stage1/apply.sh)가 마지막에 자동으로 실행하며, 아래 두 파일을 만듭니다(덮어씀).
#   - stage2/inventory.ini            : 2단계(Ansible 노드 설정)용
#   - stage3/inventory/inventory.ini  : 3단계(Kubespray)용
# 이 파일들은 매번 새로 만들어지므로 손으로 고쳐도 다음 실행 때 사라집니다.
set -euo pipefail

# 프로젝트 맨 위 폴더(이 파일의 한 단계 위)의 절대 경로
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Terraform 코드가 있는 폴더
TF_DIR="$PROJECT_ROOT/stage1/terraform"
# 인벤토리를 실제로 만들어 주는 파이썬 스크립트
GENERATOR="$PROJECT_ROOT/common/generate-inventory.py"

# 결과로 만들 두 인벤토리 파일의 위치
STAGE2_INVENTORY="$PROJECT_ROOT/stage2/inventory.ini"
STAGE3_INVENTORY="$PROJECT_ROOT/stage3/inventory/inventory.ini"

# mktemp: 임시 파일을 하나 만들어 그 경로를 얻습니다. (Terraform 출력 JSON을 잠깐 담아 둘 곳)
TMP_JSON="$(mktemp)"
# trap ... EXIT: 스크립트가 어떻게 끝나든(성공/실패) 마지막에 임시 파일을 지웁니다.
trap 'rm -f "$TMP_JSON"' EXIT

# Terraform 출력값 node_ips({노드 이름: IP})를 JSON으로 읽어 임시 파일에 저장합니다.
echo "[INFO] Reading node IPs from Terraform output..."

# terraform -chdir=폴더 : 그 폴더에서 실행한 것처럼 동작합니다. -json 은 기계가 읽기 쉬운 JSON 형식 출력입니다.
terraform -chdir="$TF_DIR" output -json node_ips > "$TMP_JSON"

# 파이썬 스크립트로 두 인벤토리 파일 생성
echo "[INFO] Generating Ansible inventories..."

# \ 는 한 줄이 길어서 다음 줄로 이어 쓴다는 표시입니다. (--input: 입력 JSON, --stage2-output/--stage3-output: 만들 파일)
python3 "$GENERATOR" \
    --input "$TMP_JSON" \
    --stage2-output "$STAGE2_INVENTORY" \
    --stage3-output "$STAGE3_INVENTORY"

echo "[PASS] Inventory generation completed."
