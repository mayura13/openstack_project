#!/usr/bin/env bash

# ==============================================================
# common.sh - 여러 스크립트가 함께 쓰는 "출력 함수" 모음
# ==============================================================
# 다른 스크립트가 맨 위에서 `source common/common.sh` 로 불러 쓰는 파일입니다.
# (source = 이 파일의 내용을 지금 스크립트 안에 그대로 가져온다는 뜻)
# 직접 실행하는 파일이 아니며, 실행해도 함수 정의만 하고 아무 일도 일어나지 않습니다.
#
# 모든 단계의 메시지 모양을 통일해서, 실패했을 때 "어느 단계, 어느 항목, 원인, 로그 위치"가
# 같은 형식으로 보이게 하는 것이 목적입니다.
#   [O]    : 통과          [X]    : 실패
#   [INFO] : 안내          [ERROR]: 실패 상세 (단계 / 항목 / 가능한 원인 / 로그 위치)
# ※ 현재 stage0, stage1 스크립트가 이 함수를 사용합니다.
#    stage2~5 스크립트는 각자 [PASS]/[FAIL] 형식으로 출력합니다.
# OpenInfra Lab Kit - Common Functions

# 제목 줄을 출력합니다. 예) print_header "Stage 1 Apply"
# local 은 "이 함수 안에서만 쓰는 변수"라는 뜻이고, $1 은 함수에 넘긴 첫 번째 값입니다.
print_header() {
    local title="$1"

    echo
    echo "========================================"
    echo " $title"
    echo "========================================"
}

# 통과 메시지 출력: print_pass "메시지"  ->  [O] 메시지
print_pass() {
    local message="$1"
    echo "[O] $message"
}

# 실패 메시지 출력: print_fail "메시지"  ->  [X] 메시지
print_fail() {
    local message="$1"
    echo "[X] $message"
}

# 안내 메시지 출력: print_info "메시지"  ->  [INFO] 메시지
print_info() {
    local message="$1"
    echo "[INFO] $message"
}

# 실패 상세 출력. 인자 4개: 단계 이름, 실패한 항목, 가능한 원인, 로그 위치.
# 사용 예) print_error_detail "Stage 1" "Terraform init" "인터넷 연결 확인" "N/A"
# 로그가 따로 없는 경우 "N/A" 를 넘기고 있습니다.
print_error_detail() {
    local stage="$1"
    local item="$2"
    local cause="$3"
    local log_path="$4"

    echo
    echo "----------------------------------------"
    echo "[ERROR]"
    echo "Stage          : $stage"
    echo "Item           : $item"
    echo "Possible cause : $cause"
    echo "Log            : $log_path"
    echo "----------------------------------------"
}