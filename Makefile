.PHONY: help \
        preflight install postcheck \
        stage-0 stage-1 stage-2 stage-3 stage-4 stage-5 \
        deploy

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
	@echo "  make deploy     - Run complete Stage 0-5 deployment"

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
	bash stage3/preflight.sh
	bash stage3/prepare.sh
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
	bash stage5/postcheck.sh

deploy: stage-0 stage-1 stage-2 stage-3 stage-4 stage-5
	@echo ""
	@echo "========================================"
	@echo " OpenInfra Lab Kit deployment complete"
	@echo "========================================"
