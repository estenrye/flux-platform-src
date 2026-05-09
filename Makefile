render-deps:
	mkdir -p .venv/bin
	.bin/install-adr.sh
	.bin/install-kustomize.sh

lint-deps:
	mkdir -p .venv/bin
	.bin/install-kube-linter.sh
	.bin/install-checkov.sh

render: render-deps
	export GITHUB_TOKEN=$${GITHUB_TOKEN:-$$(gh auth token)}; \
	export RENDER_GITHUB_TOKEN=$${RENDER_GITHUB_TOKEN:-$$(gh auth token)}; \
	.bin/render.sh

push: lint
	.bin/render/render-put-target-repository-push.sh

lint-checkov: lint-deps
	.venv-checkov/bin/checkov -d .render/ --framework kubernetes --quiet --compact --skip-results-upload

lint-kube-linter: lint-deps
	find .render -type f -name "*.yaml" -o -name "*.yml" \
	  | xargs .venv/bin/kube-linter lint --config .kube-linter/config.yaml

lint: lint-deps render lint-checkov lint-kube-linter