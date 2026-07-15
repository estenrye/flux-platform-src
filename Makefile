# Prevent gh CLI from opening a pager (less/more) for API responses
export GH_PAGER=cat

render-deps:
	mkdir -p .venv/bin
	.bin/install-adr.sh
	.bin/install-kustomize.sh

lint-deps:
	mkdir -p .venv/bin
	.bin/install-kube-linter.sh
	.bin/install-checkov.sh

render-manifests: render-deps
	.bin/render-manifests.sh

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
	.venv/bin/kube-linter lint --config .kube-linter/config.yaml .render

# ADR-16 drift guard: Spot silently ran with the csi-driver-spiffe default
# trust domain (cluster.local) for weeks — M0 audit finding. Fail the lint
# if any non-Spot cluster render carries it (Spot keeps it until decommission).
lint-trust-domain:
	@BAD=$$(grep -rl -- '--trust-domain=cluster.local\|trust-domain: cluster.local' .render/*/clusters/* 2>/dev/null | grep -v '/clusters/crossplane/' || true); \
	if [ -n "$$BAD" ]; then echo "ADR-16 VIOLATION: trust domain cluster.local rendered outside Spot:"; echo "$$BAD"; exit 1; fi; \
	echo "trust-domain guard: OK"

lint: lint-deps render lint-checkov lint-kube-linter lint-trust-domain

flux-reconcile-source:
	flux reconcile source git flux-platform-rendered -n flux-system

flux-reconcile-kustomization:
	flux reconcile kustomization flux-platform -n flux-system --with-source
	flux reconcile kustomization flux-platform-external-dns-aws-rolesanywhere -n flux-system --with-source

auth-aws:
	.venv/bin/awscliv2 sso login \
		--profile ops-opex-dns-automation \
		--region us-east-2 \
		--no-browser \
		--use-device-code

aws-deploy-cloudformation-stack-rolesanywhere:
	.bin/deploy-aws-roles-anywhere.sh

aws-get-cloudformation-stack-outputs-trust-anchor-arn:
	.venv/bin/awscliv2 cloudformation describe-stacks \
		--profile ops-opex-dns-automation \
		--stack-name crossplane-provider-dns-admin \
		--output json \
		| jq -r '.Stacks[0].Outputs[] | select(.OutputKey=="TrustAnchorArn") | .OutputValue'

aws-get-cloudformation-stack-outputs-trust-anchor-id:
	.venv/bin/awscliv2 cloudformation describe-stacks \
		--profile ops-opex-dns-automation \
		--stack-name crossplane-provider-dns-admin \
		--output json \
		| jq -r '.Stacks[0].Outputs[] | select(.OutputKey=="TrustAnchorId") | .OutputValue'

aws-get-cloudformation-stack-outputs-profile-arn:
	.venv/bin/awscliv2 cloudformation describe-stacks \
		--profile ops-opex-dns-automation \
		--stack-name crossplane-provider-dns-admin \
		--output json \
		| jq -r '.Stacks[0].Outputs[] | select(.OutputKey=="ProfileArn") | .OutputValue'


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

bootstrap-access:
	.bin/bootstrap-access.sh

bootstrap-github-app:
	.bin/bootstrap-github-app.sh

bootstrap-ci:
	.bin/bootstrap-ci.sh

bootstrap-cluster-catalog:
	CLUSTER=$(CLUSTER) KUBECONFIG=$(KUBECONFIG) .bin/bootstrap-cluster-catalog.sh

bootstrap-cluster-environment:
	CLUSTER=$(CLUSTER) .bin/bootstrap-cluster-environment.sh

bootstrap-cluster-rendered-repo:
	CLUSTER=$(CLUSTER) .bin/bootstrap-cluster-rendered-repo.sh

bootstrap-cluster-sops-key:
	CLUSTER=$(CLUSTER) .bin/bootstrap-cluster-sops-key.sh

bootstrap-cluster-deploy-key:
	CLUSTER=$(CLUSTER) .bin/bootstrap-cluster-deploy-key.sh

deploy-cluster:
	CLUSTER=$(CLUSTER) .bin/deploy-cluster.sh

bootstrap-cluster: bootstrap-cluster-catalog bootstrap-cluster-environment bootstrap-cluster-rendered-repo bootstrap-cluster-sops-key

get-cloudspace-kubeconfigs:
	@.bin/get-cloudspace-kubeconfigs.sh

teardown-cluster:
	CLUSTER=$(CLUSTER) SKIP_K8S=$(SKIP_K8S) .bin/teardown-cluster.sh

teardown-cluster-full:
	CLUSTER=$(CLUSTER) SKIP_K8S=$(SKIP_K8S) .bin/teardown-cluster.sh --full

rotate-cluster-deploy-key:
	CLUSTER=$(CLUSTER) .bin/rotate-cluster-deploy-key.sh

rotate-cluster-service-account-token:
	CLUSTER=$(CLUSTER) .bin/rotate-cluster-service-account-token.sh

rotate-cluster-sops-key:
	CLUSTER=$(CLUSTER) .bin/rotate-cluster-sops-key.sh

rotate-github-app-credentials:
	.bin/rotate-github-app-credentials.sh

rotate-ci-service-account:
	.bin/rotate-ci-service-account.sh
