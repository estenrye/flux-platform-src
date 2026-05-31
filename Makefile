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

push-branch:
	.bin/render/render-put-target-repository-push.sh

push-pr: push-branch
	bash .bin/render/render-put-target-repository-pr.sh

push: lint push-pr

lint-checkov: lint-deps
	.venv/bin/checkov -d .render/ --framework kubernetes --quiet --compact --skip-results-upload

lint-kube-linter: lint-deps
	find .render -type f -name "*.yaml" -o -name "*.yml" \
	  | xargs .venv/bin/kube-linter lint --config .kube-linter/config.yaml

lint: lint-deps render lint-checkov lint-kube-linter

auth-aws:
	.venv/bin/awscliv2 sso login \
		--profile ops-opex-dns-automation \
		--region us-east-2 \
		--no-browser \
		--use-device-code

aws-list-rolesanywhere-trust-anchors:
	.venv/bin/awscliv2 rolesanywhere list-trust-anchors --profile ops-opex-dns-automation \
		| jq '.trustAnchors | map({ name:.name, trustAnchorId:.trustAnchorId, trustAnchorArn:.trustAnchorArn,enabled:.enabled })'

aws-list-rolesanywhere-profiles:
	.venv/bin/awscliv2 rolesanywhere list-profiles --profile ops-opex-dns-automation \
		| jq '.profiles | map({ name:.name, profileId:.profileId, enabled:.enabled, roleArns:.roleArns })'

aws-disable-rolesanywhere-trust-anchor:
	@test -n "$(TRUST_ANCHOR_ID)" || (echo "Usage: make aws-disable-rolesanywhere-trust-anchor TRUST_ANCHOR_ID=<id>"; exit 1)
	.venv/bin/awscliv2 rolesanywhere disable-trust-anchor \
		--trust-anchor-id $(TRUST_ANCHOR_ID) \
		--profile ops-opex-dns-automation \
		--region us-east-2

aws-enable-rolesanywhere-trust-anchor:
	@test -n "$(TRUST_ANCHOR_ID)" || (echo "Usage: make aws-enable-rolesanywhere-trust-anchor TRUST_ANCHOR_ID=<id>"; exit 1)
	.venv/bin/awscliv2 rolesanywhere enable-trust-anchor \
		--trust-anchor-id $(TRUST_ANCHOR_ID) \
		--profile ops-opex-dns-automation \
		--region us-east-2

aws-disable-rolesanywhere-profile:
	@test -n "$(PROFILE_ID)" || (echo "Usage: make aws-disable-rolesanywhere-profile PROFILE_ID=<id>"; exit 1)
	.venv/bin/awscliv2 rolesanywhere disable-profile \
		--profile-id $(PROFILE_ID) \
		--profile ops-opex-dns-automation \
		--region us-east-2

aws-enable-rolesanywhere-profile:
	@test -n "$(PROFILE_ID)" || (echo "Usage: make aws-enable-rolesanywhere-profile PROFILE_ID=<id>"; exit 1)
	.venv/bin/awscliv2 rolesanywhere enable-profile \
		--profile-id $(PROFILE_ID) \
		--profile ops-opex-dns-automation \
		--region us-east-2
