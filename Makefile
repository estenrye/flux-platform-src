MAKEFILE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SCRIPTS_DIR := $(abspath $(MAKEFILE_DIR).bin)
VENV_BIN_DIR := $(abspath $(MAKEFILE_DIR).venv/bin)

render-deps:
	mkdir -p ${VENV_BIN_DIR}
	@${SCRIPTS_DIR}/install-adr.sh
	@${SCRIPTS_DIR}/install-kustomize.sh

render:
	@${SCRIPTS_DIR}/render.sh