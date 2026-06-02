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
	SPIFFE_CA_NAME=csi-driver-spiffe-ca
	SPIFFE_CA_SECRET_NAME=$$(kubectl get certificate -n cert-manager csi-driver-spiffe-ca -o jsonpath='{.spec.secretName}')
	SPIFFE_CA_CERT=$$(kubectl get secret -n cert-manager ${SPIFFE_CA_SECRET_NAME} -o jsonpath='{.data.ca\.crt}' | base64 --decode)
	.venv/bin/awscliv2 cloudformation deploy \
		--profile ops-opex-dns-automation \
		--stack-name crossplane-provider-dns-admin \
		--template-file providers/aws/crossplane-iam-roles-anywhere.yaml \
		--parameter-overrides \
			ParameterKey=RoleName,ParameterValue=crossplane-provider-dns-admin \
			ParameterKey=SpiffeUri,ParameterValue=spiffe://cluster.local/ns/crossplane-system/sa/aws-route53-dns-provider \
			ParameterKey=CaX509Cert,ParameterValue="${SPIFFE_CA_CERT}" \
		--capabilities CAPABILITY_NAMED_IAM

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
