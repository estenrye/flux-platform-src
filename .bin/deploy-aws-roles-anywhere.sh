#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

SPIFFE_CA_CERT=$(kubectl get secret -n cert-manager csi-driver-spiffe-ca -o jsonpath='{.data.ca\.crt}')
.venv/bin/awscliv2 cloudformation deploy \
    --profile ops-opex-dns-automation \
    --stack-name crossplane-provider-dns-admin \
    --template-file providers/aws/crossplane-iam-roles-anywhere.yaml \
    --parameter-overrides \
        ParameterKey=RoleName,ParameterValue=crossplane-provider-dns-admin \
        ParameterKey=SpiffeUri,ParameterValue=spiffe://cluster.local/ns/crossplane-system/sa/aws-route53-dns-provider \
        ParameterKey=CaX509Cert,ParameterValue="${SPIFFE_CA_CERT}" \
    --capabilities CAPABILITY_NAMED_IAM