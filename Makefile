.PHONY: help preflight install postcheck stage-0

help:
	@echo "OpenInfra Lab Kit"
	@echo ""
	@echo "Available commands:"
	@echo "  make preflight  - Run Stage 0 environment checks"
	@echo "  make install    - Install Stage 0 dependencies"
	@echo "  make postcheck  - Verify Stage 0 installation"
	@echo "  make stage-0    - Run complete Stage 0"

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