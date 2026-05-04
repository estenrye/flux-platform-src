MAKEFILE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SCRIPTS_DIR := $(abspath $(MAKEFILE_DIR).bin)
VENV_BIN_DIR := $(abspath $(MAKEFILE_DIR).venv/bin)

render-deps:
	mkdir -p ${VENV_BIN_DIR}
	@${SCRIPTS_DIR}/install-adr.sh
	@${SCRIPTS_DIR}/install-kustomize.sh

lint-deps:
	mkdir -p ${VENV_BIN_DIR}
	@${SCRIPTS_DIR}/install-kube-linter.sh

render: render-deps
	@export GITHUB_TOKEN=$${GITHUB_TOKEN:-$$(gh auth token)}; \
	export RENDER_GITHUB_TOKEN=$${RENDER_GITHUB_TOKEN:-$$(gh auth token)}; \
	${SCRIPTS_DIR}/render.sh

push-render: render
	@${SCRIPTS_DIR}/render/render-put-target-repository-push.sh

lint: lint-deps render
	@${SCRIPTS_DIR}/lint.sh