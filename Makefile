.PHONY: help \
        preflight install postcheck \
        stage-0 stage-1 stage-2 stage-3 stage-4 stage-5 stage-6 \
        deploy deploy-from reset-dry-run reset

help:
	@echo "OpenInfra Lab Kit"
	@echo ""
	@echo "Available commands:"
	@echo "  make preflight  - Run Stage 0 environment checks"
	@echo "  make install    - Install Stage 0 dependencies"
	@echo "  make postcheck  - Verify Stage 0 installation"
	@echo "  make stage-0    - Run Stage 0 environment setup"
	@echo "  make stage-1    - Provision VMs with Terraform"
	@echo "  make stage-2    - Configure Kubernetes nodes with Ansible"
	@echo "  make stage-3    - Deploy Kubernetes with Kubespray"
	@echo "  make stage-4    - Prepare OpenStack-Helm prerequisites"
	@echo "  make stage-5    - Deploy OpenStack with OpenStack-Helm"
	@echo "  make stage-6    - Verify OpenStack services and collect final state"
	@echo "  make deploy         - Run complete Stage 0-6 deployment"
	@echo "  make deploy-from FROM_STAGE=N - Run Stage N-6 only (Stage 0 already done)"
	@echo "  make reset-dry-run  - Show resources targeted for clean-state reset"
	@echo "  make reset          - Reset OpenInfra Lab Kit resources"

preflight:
	bash stage0/preflight.sh

install:
	bash stage0/install.sh

postcheck:
	bash stage0/postcheck.sh

stage-0:
	bash stage0/preflight.sh
	bash stage0/install.sh
	bash stage0/postcheck.sh

stage-1:
	bash stage1/apply.sh
	bash stage1/postcheck.sh

stage-2:
	bash stage2/preflight.sh
	cd stage2 && ANSIBLE_CONFIG=ansible.cfg \
		$(HOME)/venv-kubespray/bin/ansible-playbook prepare-nodes.yml
	bash stage2/postcheck.sh

stage-3:
	bash stage3/prepare.sh
	bash stage3/preflight.sh
	bash stage3/deploy.sh
	bash stage3/postcheck.sh

stage-4:
	bash stage4/prepare.sh
	bash stage4/configure-nodes.sh
	bash stage4/configure-storage.sh
	bash stage4/postcheck.sh

stage-5:
	bash stage5/preflight.sh
	bash stage5/deploy.sh
	bash stage5/wait-ready.sh

# 6단계(검증, 상태 수집) 결과를 저장할 폴더입니다.
# 기본값은 logs/evaluation 이지만, 회차마다 결과가 섞이지 않도록 make 실행 때 값을 바꿔 줄 수 있습니다.
#   예) make stage-6 EVAL_DIR=logs/run-01/evaluation
# (run-deploy.sh 는 회차마다 logs/<run-id>/evaluation 을 자동으로 넘겨 줍니다)
EVAL_DIR ?= logs/evaluation

stage-6:
	@mkdir -p $(EVAL_DIR)
	bash stage6/verify-services.sh $(EVAL_DIR)/verify
	bash stage6/collect-state.sh $(EVAL_DIR)/final-state

deploy: stage-0 stage-1 stage-2 stage-3 stage-4 stage-5 stage-6
	@echo ""
	@echo "========================================"
	@echo " OpenInfra Lab Kit deployment complete"
	@echo "========================================"

# 지정한 단계부터 6단계까지만 순서대로 실행합니다. (make deploy 는 항상 0단계부터 시작)
# 0단계(도구 설치)를 이미 끝낸 환경에서 1단계부터 반복 실험할 때 사용합니다.
#   예) make deploy-from FROM_STAGE=1
FROM_STAGE ?= 1

deploy-from:
	@case "$(FROM_STAGE)" in [0-6]) ;; *) echo "[FAIL] FROM_STAGE must be a number from 0 to 6 (got: $(FROM_STAGE))"; exit 1 ;; esac
	@for n in 0 1 2 3 4 5 6; do \
		if [ "$$n" -ge "$(FROM_STAGE)" ]; then \
			echo ""; echo ">>> make stage-$$n"; \
			$(MAKE) --no-print-directory stage-$$n || exit $$?; \
		fi; \
	done
	@echo ""
	@echo "========================================"
	@echo " OpenInfra Lab Kit deployment complete (Stage $(FROM_STAGE)-6)"
	@echo "========================================"

reset-dry-run:
	bash scripts/reset-lab.sh --dry-run

reset:
	bash scripts/reset-lab.sh --execute
