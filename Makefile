# Prevent gh CLI from opening a pager (less/more) for API responses
export GH_PAGER=cat

render-deps:
	mkdir -p .venv/bin
	.bin/install-adr.sh
	.bin/install-kustomize.sh
	.bin/install-yq.sh

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
# trust domain (cluster.local) for weeks (M0 audit finding). Renders each
# cluster and asserts exactly one --trust-domain arg per container, never
# cluster.local.
lint-spiffe-trust-domain: render-deps
	PATH="$(CURDIR)/.venv/bin:$$PATH" .bin/lint-spiffe-trust-domain.sh $(dir $(wildcard clusters/*/kustomization.yaml))

test-lint-spiffe-trust-domain: render-deps
	PATH="$(CURDIR)/.venv/bin:$$PATH" .bin/test/test-lint-spiffe-trust-domain.sh

# Netdata's base ships the placeholder hostname netdata.k8s.local on both the
# Gateway listener and the HTTPRoute; every cluster including netdata must
# patch both. Silent no-op patches would otherwise leave the placeholder live.
lint-netdata-hostname: render-deps
	PATH="$(CURDIR)/.venv/bin:$$PATH" .bin/lint-netdata-hostname.sh $(dir $(wildcard clusters/*/kustomization.yaml))

test-lint-netdata-hostname: render-deps
	PATH="$(CURDIR)/.venv/bin:$$PATH" .bin/test/test-lint-netdata-hostname.sh

# Grafana's base ships placeholders for the hostname (Gateway, HTTPRoute,
# GF_SERVER_ROOT_URL) and the JumpCloud client id; every cluster including
# grafana must patch them.
lint-grafana-placeholders: render-deps
	PATH="$(CURDIR)/.venv/bin:$$PATH" .bin/lint-grafana-placeholders.sh $(dir $(wildcard clusters/*/kustomization.yaml))

test-lint-grafana-placeholders: render-deps
	PATH="$(CURDIR)/.venv/bin:$$PATH" .bin/test/test-lint-grafana-placeholders.sh

# external-dns on the TXT registry without --txt-owner-id uses the owner
# "default", so clusters sharing a DNS zone delete each other's records.
lint-external-dns-owner-id: render-deps
	PATH="$(CURDIR)/.venv/bin:$$PATH" .bin/lint-external-dns-owner-id.sh $(dir $(wildcard clusters/*/kustomization.yaml))

test-lint-external-dns-owner-id: render-deps
	PATH="$(CURDIR)/.venv/bin:$$PATH" .bin/test/test-lint-external-dns-owner-id.sh

# seaweedfs-db's base ships the placeholder R2 endpoint
# https://CF_ACCOUNT_ID.r2.cloudflarestorage.com on its barman ObjectStore;
# every cluster including seaweedfs-db must patch in the real account endpoint.
lint-seaweedfs-db-barman-endpoint: render-deps
	PATH="$(CURDIR)/.venv/bin:$$PATH" .bin/lint-seaweedfs-db-barman-endpoint.sh $(dir $(wildcard clusters/*/kustomization.yaml))

test-lint-seaweedfs-db-barman-endpoint: render-deps
	PATH="$(CURDIR)/.venv/bin:$$PATH" .bin/test/test-lint-seaweedfs-db-barman-endpoint.sh

# Kustomize can't share a Helm values file across overlays, so
# applications/minecraft/<instance>/base.values.yaml is generated from
# applications/minecraft/base/values.yaml; fail if a copy is stale.
lint-minecraft-values:
	.bin/sync-minecraft-values.sh --check

lint: lint-deps render lint-minecraft-values lint-checkov lint-kube-linter lint-spiffe-trust-domain lint-netdata-hostname lint-grafana-placeholders lint-external-dns-owner-id lint-seaweedfs-db-barman-endpoint

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

bootstrap-cluster-secret-store:
	CLUSTER=$(CLUSTER) KUBECONFIG=$(KUBECONFIG) VAULT_USERS=$(VAULT_USERS) .bin/bootstrap-cluster-secret-store.sh

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

install-calicoctl:
	mkdir -p .venv/bin
	.bin/install-calicoctl.sh

# Detect leaked Calico LoadBalancer IPAM allocations that make an address flap.
# Usage: CLUSTER=core-infra make detect-calico-ipam-flapping
#        add WATCH=330 to also watch Services/Gateways for address changes.
detect-calico-ipam-flapping:
	CLUSTER=$(CLUSTER) .bin/detect-calico-ipam-flapping.sh $(if $(WATCH),--watch $(WATCH))

# Reproduce the Calico LoadBalancer stale-handle bug on a throwaway Service and
# report whether the running Calico version has it (docs/research/calico-bgp-iam-flap-ipv6.md).
# Briefly force-restarts calico-kube-controllers. Takes about 6 minutes.
# Usage: CLUSTER=core-infra make reproduce-calico-lb-stale-handle
reproduce-calico-lb-stale-handle: install-calicoctl
	CLUSTER=$(CLUSTER) .bin/reproduce-calico-lb-stale-handle.sh

# Release a leaked Calico LoadBalancer IPAM allocation (see the script header).
# Usage: CLUSTER=core-infra IP=<address> make release-calico-ipam-allocation
#        add DRY_RUN=true to preview without releasing.
release-calico-ipam-allocation: install-calicoctl
	@test -n "$(IP)" || { echo "Usage: CLUSTER=<cluster> IP=<address> [DRY_RUN=true] make release-calico-ipam-allocation" >&2; exit 1; }
	CLUSTER=$(CLUSTER) .bin/release-calico-ipam-allocation.sh $(IP) $(if $(filter true,$(DRY_RUN)),--dry-run)

rotate-github-app-credentials:
	.bin/rotate-github-app-credentials.sh

rotate-ci-service-account:
	.bin/rotate-ci-service-account.sh

provision-democratic-csi:
	CLUSTER=$(CLUSTER) NFS_SERVER_ULA=$(NFS_SERVER_ULA) .bin/provision-democratic-csi.sh

provision-cloudflare-r2-bucket:
	CLUSTER=$(CLUSTER) BUCKET_NAME=$(BUCKET_NAME) SECRET_NS=$(SECRET_NS) CF_API_TOKEN=$(CF_API_TOKEN) .bin/provision-cloudflare-r2-bucket.sh

rotate-cloudflare-r2-token:
	CLUSTER=$(CLUSTER) BUCKET_NAME=$(BUCKET_NAME) CF_API_TOKEN=$(CF_API_TOKEN) .bin/rotate-cloudflare-r2-token.sh
