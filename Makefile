MAKEFILE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SCRIPTS_DIR := $(abspath $(MAKEFILE_DIR).bin)

render-deps:
	@${SCRIPTS_DIR}/install-kustomize.sh

render:
	@${SCRIPTS_DIR}/render.sh