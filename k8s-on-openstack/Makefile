# OpenInfra Lab Kit — Kubernetes on OpenStack
# 현재 구현된 단계: 0~6단계. 나머지 단계는 구현하면서 같은 형식(stage-N)으로 추가한다.
#
#   make preflight      0단계 설치 전 점검만
#   make install        0단계 도구 설치만 (이미 설치된 것은 건너뜀)
#   make postcheck      0단계 설치 후 점검만
#   make stage-0        preflight -> install -> postcheck
#   make stage1-preflight / stage1-plan / stage1-apply / stage1-postcheck
#   make stage-1        1단계 전체(preflight -> apply -> postcheck)
#   make stage2-preflight / stage2-plan / stage2-apply / stage2-postcheck / verify-a
#   make stage-2        2단계 전체(preflight -> apply -> postcheck -> verify-a). 이미지 빌드가 있으면 tmux 안에서
#   make stage3-preflight / stage3-plan / stage3-apply / stage3-postcheck
#   make stage-3        3단계 전체(preflight -> apply -> postcheck)
#   make stage4-preflight / stage4-plan / stage4-apply / stage4-postcheck
#   make stage-4        4단계 전체(preflight -> apply -> postcheck)
#   make stage5-preflight / stage5-plan / stage5-apply / stage5-postcheck / verify-bcde
#   make stage-5        5단계 전체(preflight -> apply -> postcheck -> verify-bcde)
#   make stage6-preflight / stage6-plan / stage6-apply / verify-f
#   make stage-6        6단계(preflight -> 클러스터 삭제 -> 검증 f). 삭제는 클러스터 이름을 직접 입력해야 진행
#   make verify         검증 a~f 전체(상황에 맞는 것만 실행, 삭제 안 함)
#   make clean-check    회차 시작 전 깨끗한 상태 확인 (읽기 전용)
#   make install-plan   설치 계획만 출력(dry-run)
#
# 옵션: KIT_ASSUME_YES=1 (확인 질문 없이), KIT_LOG_DIR=<폴더>, FORCE_REINSTALL=1
# 설치 단계가 종료 코드 2로 끝나면 실패가 아니라 "재접속 후 재실행" 안내다.

SHELL := /bin/bash
.DEFAULT_GOAL := help
.PHONY: help preflight install install-plan postcheck stage-0 clean-check stage1-preflight stage1-plan stage1-apply stage1-postcheck stage-1 stage2-preflight stage2-plan stage2-apply stage2-postcheck verify-a stage-2 stage3-preflight stage3-plan stage3-apply stage3-postcheck stage-3 stage4-preflight stage4-plan stage4-apply stage4-postcheck stage-4 stage5-preflight stage5-plan stage5-apply stage5-postcheck verify-bcde stage-5 stage6-preflight stage6-plan stage6-apply verify-f stage-6 verify

help:
	@sed -n '2,26p' Makefile | sed 's/^# \{0,1\}//'

preflight:
	@bash stage0/preflight.sh

install:
	@bash stage0/install.sh

install-plan:
	@bash stage0/install.sh --dry-run

postcheck:
	@bash stage0/postcheck.sh

# 단계 안에서 하나라도 실패하면 그 종료 코드로 멈춘다.
stage-0:
	@echo "===== Stage 0: preflight ====="
	@bash stage0/preflight.sh
	@echo "===== Stage 0: install ====="
	@bash stage0/install.sh
	@echo "===== Stage 0: postcheck ====="
	@bash stage0/postcheck.sh

clean-check:
	@bash stage0/check-clean-state.sh

stage1-preflight:
	@bash stage1/preflight.sh

stage1-plan:
	@bash stage1/apply.sh --dry-run

stage1-apply:
	@bash stage1/apply.sh

stage1-postcheck:
	@bash stage1/postcheck.sh

# apply 가 종료 코드 2(재접속 필요)로 끝나면 여기서 멈춘다. 재접속 뒤 다시 실행하면 postcheck 까지 진행한다.
stage-1:
	@echo "===== Stage 1: preflight ====="
	@bash stage1/preflight.sh
	@echo "===== Stage 1: apply ====="
	@bash stage1/apply.sh
	@echo "===== Stage 1: postcheck ====="
	@bash stage1/postcheck.sh

stage2-preflight:
	@bash stage2/preflight.sh

stage2-plan:
	@bash stage2/apply.sh --dry-run

stage2-apply:
	@bash stage2/apply.sh

stage2-postcheck:
	@bash stage2/postcheck.sh

verify-a:
	@bash stage2/verify-a.sh

stage-2:
	@echo "===== Stage 2: preflight ====="
	@bash stage2/preflight.sh
	@echo "===== Stage 2: apply ====="
	@bash stage2/apply.sh
	@echo "===== Stage 2: postcheck ====="
	@bash stage2/postcheck.sh
	@echo "===== Stage 2: verify a ====="
	@bash stage2/verify-a.sh

stage3-preflight:
	@bash stage3/preflight.sh

stage3-plan:
	@bash stage3/apply.sh --dry-run

stage3-apply:
	@bash stage3/apply.sh

stage3-postcheck:
	@bash stage3/postcheck.sh

# apply 가 종료 코드 2(재접속 필요)로 끝나면 여기서 멈춘다.
stage-3:
	@echo "===== Stage 3: preflight ====="
	@bash stage3/preflight.sh
	@echo "===== Stage 3: apply ====="
	@bash stage3/apply.sh
	@echo "===== Stage 3: postcheck ====="
	@bash stage3/postcheck.sh

stage4-preflight:
	@bash stage4/preflight.sh

stage4-plan:
	@bash stage4/apply.sh --dry-run

stage4-apply:
	@bash stage4/apply.sh

stage4-postcheck:
	@bash stage4/postcheck.sh

stage-4:
	@echo "===== Stage 4: preflight ====="
	@bash stage4/preflight.sh
	@echo "===== Stage 4: apply ====="
	@bash stage4/apply.sh
	@echo "===== Stage 4: postcheck ====="
	@bash stage4/postcheck.sh

stage5-preflight:
	@bash stage5/preflight.sh

stage5-plan:
	@bash stage5/apply.sh --dry-run

stage5-apply:
	@bash stage5/apply.sh

stage5-postcheck:
	@bash stage5/postcheck.sh

verify-bcde:
	@bash stage5/verify-bcde.sh

stage-5:
	@echo "===== Stage 5: preflight ====="
	@bash stage5/preflight.sh
	@echo "===== Stage 5: apply ====="
	@bash stage5/apply.sh
	@echo "===== Stage 5: postcheck ====="
	@bash stage5/postcheck.sh
	@echo "===== Stage 5: verify b~e ====="
	@bash stage5/verify-bcde.sh

stage6-preflight:
	@bash stage6/preflight.sh

stage6-plan:
	@bash stage6/apply.sh --dry-run

stage6-apply:
	@bash stage6/apply.sh

verify-f:
	@bash stage6/verify-f.sh

stage-6:
	@echo "===== Stage 6: preflight ====="
	@bash stage6/preflight.sh
	@echo "===== Stage 6: 삭제와 검증 f ====="
	@bash stage6/apply.sh
	@echo "===== Stage 6: verify f ====="
	@bash stage6/verify-f.sh

verify:
	@bash verify/all.sh
