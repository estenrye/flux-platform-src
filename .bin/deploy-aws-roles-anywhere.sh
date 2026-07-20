#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AWS_PROFILE="${AWS_PROFILE:-ops-opex-dns-automation}"
TOP_LEVEL_DOMAIN="${TOP_LEVEL_DOMAIN:-rye.ninja}"

cd "${REPO_ROOT}"
source "${SCRIPT_DIR}/lib/prompt-color.sh"
source "${SCRIPT_DIR}/lib/prompt-cluster.sh"
source "${SCRIPT_DIR}/lib/prompt-kubeconfig.sh"

function deploy_iam_policy_stack() {
    local stack_name="$1"
    local template_file="$2"

    docker run --rm \
        -v ${HOME}/.aws:/root/.aws \
        -v ${REPO_ROOT}:/aws \
        -e AWS_PROFILE="${AWS_PROFILE}" \
        -e stack_name="${stack_name}" \
        amazon/aws-cli \
          cloudformation deploy \
            --profile "${AWS_PROFILE}" \
            --stack-name "${stack_name}" \
            --template-file "${template_file}" \
            --capabilities CAPABILITY_NAMED_IAM
}

function get_iam_policy_arn() {
    local stack_name="$1"
    local output_key="$2"

    docker run --rm \
        -v ${HOME}/.aws:/root/.aws \
        -v ${REPO_ROOT}:/aws \
        -e AWS_PROFILE="${AWS_PROFILE}" \
        -e stack_name="${stack_name}" \
        -e output_key="${output_key}" \
        amazon/aws-cli \
          cloudformation describe-stacks \
            --profile "${AWS_PROFILE}" \
            --stack-name "${stack_name}" \
            --output json \
            | jq -r ".Stacks[0].Outputs[] | select(.OutputKey==\"${output_key}\") | .OutputValue"
}

# deploy the base64 decode lambda function

docker run --rm \
    -v ${HOME}/.aws:/root/.aws \
    -v ${REPO_ROOT}:/aws \
    amazon/aws-cli \
      cloudformation deploy \
        --profile ops-opex-dns-automation \
        --stack-name base64-decode-lambda-function \
        --template-file providers/aws/lambda-functions/base64-decode-lambda-function.yaml \
        --capabilities CAPABILITY_NAMED_IAM

export BASE64_DECODE_FUNCTION_ARN=$(docker run --rm \
    -v ${HOME}/.aws:/root/.aws \
    -v ${REPO_ROOT}:/aws \
    amazon/aws-cli \
      cloudformation describe-stacks \
        --profile ops-opex-dns-automation \
        --stack-name base64-decode-lambda-function \
        --output json \
        | jq -r '.Stacks[0].Outputs[] | select(.OutputKey=="Base64DecodeFunctionArn") | .OutputValue')

echo "Base64 Decode Lambda Function ARN: ${BASE64_DECODE_FUNCTION_ARN}"

# deploy the IAM Admin policy for Roles Anywhere
deploy_iam_policy_stack "crossplane-provider-iam-admin-policy" "providers/aws/iam-policies/iam-admin-policy.yaml"
export IAM_ADMIN_POLICY_ARN=$(get_iam_policy_arn "crossplane-provider-iam-admin-policy" "IAMPolicyArn")

echo "IAM Admin Policy ARN: ${IAM_ADMIN_POLICY_ARN}"

# deploy the Route53 Admin policy for Roles Anywhere
deploy_iam_policy_stack "crossplane-provider-route53-admin-policy" "providers/aws/iam-policies/route53-admin-policy.yaml"
export ROUTE53_ADMIN_POLICY_ARN=$(get_iam_policy_arn "crossplane-provider-route53-admin-policy" "IAMPolicyArn")

echo "Route53 Admin Policy ARN: ${ROUTE53_ADMIN_POLICY_ARN}"

# deploy the Roles Anywhere IAM Admin policy for Roles Anywhere
deploy_iam_policy_stack "crossplane-provider-roles-anywhere-admin-policy" "providers/aws/iam-policies/roles-anywhere-admin-policy.yaml"
export ROLES_ANYWHERE_ADMIN_POLICY_ARN=$(get_iam_policy_arn "crossplane-provider-roles-anywhere-admin-policy" "IAMPolicyArn")

echo "Roles Anywhere IAM Admin Policy ARN: ${ROLES_ANYWHERE_ADMIN_POLICY_ARN}"

# Get the base64 string directly (it is already base64 encoded in the secret)
export SPIFFE_CA_CERT=$(kubectl get secret -n cert-manager csi-driver-spiffe-ca -o jsonpath='{.data.ca\.crt}' | tr -d '\n')

jq -n \
  --arg arn "${BASE64_DECODE_FUNCTION_ARN}" \
  --arg cert "${SPIFFE_CA_CERT}" \
  --arg clusterCN "${CLUSTER}.${TOP_LEVEL_DOMAIN}" \
  --arg iamAdminPolicyArn "${IAM_ADMIN_POLICY_ARN}" \
  --arg route53AdminPolicyArn "${ROUTE53_ADMIN_POLICY_ARN}" \
  --arg rolesAnywhereAdminPolicyArn "${ROLES_ANYWHERE_ADMIN_POLICY_ARN}" \
  '[
      { "ParameterKey": "Base64DecodeFunctionArn", "ParameterValue": $arn },
      { "ParameterKey": "CaX509Cert", "ParameterValue": $cert },
      { "ParameterKey": "ClusterCN", "ParameterValue": $clusterCN },
      { "ParameterKey": "IAMAdminPolicyArn", "ParameterValue": $iamAdminPolicyArn },
      { "ParameterKey": "Route53AdminPolicyArn", "ParameterValue": $route53AdminPolicyArn },
      { "ParameterKey": "RolesAnywhereAdminPolicyArn", "ParameterValue": $rolesAnywhereAdminPolicyArn }
  ]' \
  > "clusters/${CLUSTER}/deploy-aws-roles-anywhere-parameters.json"

cat "clusters/${CLUSTER}/deploy-aws-roles-anywhere-parameters.json"

# Deploy
docker run --rm \
    -v ${HOME}/.aws:/root/.aws \
    -v ${REPO_ROOT}:/aws \
    -e CLUSTER=${CLUSTER} \
    amazon/aws-cli \
      cloudformation deploy \
        --profile ops-opex-dns-automation \
        --stack-name ${CLUSTER}-Trust-Anchor \
        --template-file providers/aws/roles-anywhere/trust-anchor.yaml \
        --parameter-overrides $(jq -r '.[] | [.ParameterKey, .ParameterValue] | "\(.[0])=\(.[1])"' "clusters/${CLUSTER}/deploy-aws-roles-anywhere-parameters.json")

docker run --rm \
    -v ${HOME}/.aws:/root/.aws \
    -v ${REPO_ROOT}:/aws \
    -e CLUSTER=${CLUSTER} \
    amazon/aws-cli \
      cloudformation deploy \
        --profile ops-opex-dns-automation \
        --stack-name ${CLUSTER}-IAM-Admin \
        --template-file providers/aws/iam-roles/trust-anchor-iam-admin.yaml \
        --parameter-overrides $(jq -r '.[] | [.ParameterKey, .ParameterValue] | "\(.[0])=\(.[1])"' "clusters/${CLUSTER}/deploy-aws-roles-anywhere-parameters.json") \
        --capabilities CAPABILITY_NAMED_IAM

docker run --rm \
    -v ${HOME}/.aws:/root/.aws \
    -v ${REPO_ROOT}:/aws \
    -e CLUSTER=${CLUSTER} \
    amazon/aws-cli \
      cloudformation deploy \
        --profile ops-opex-dns-automation \
        --stack-name ${CLUSTER}-Route53-Admin \
        --template-file providers/aws/iam-roles/trust-anchor-route53-admin.yaml \
        --parameter-overrides $(jq -r '.[] | [.ParameterKey, .ParameterValue] | "\(.[0])=\(.[1])"' "clusters/${CLUSTER}/deploy-aws-roles-anywhere-parameters.json") \
        --capabilities CAPABILITY_NAMED_IAM

docker run --rm \
    -v ${HOME}/.aws:/root/.aws \
    -v ${REPO_ROOT}:/aws \
    -e CLUSTER=${CLUSTER} \
    amazon/aws-cli \
      cloudformation deploy \
        --profile ops-opex-dns-automation \
        --stack-name ${CLUSTER}-RA-Admin \
        --template-file providers/aws/iam-roles/trust-anchor-roles-anywhere-admin.yaml \
        --parameter-overrides $(jq -r '.[] | [.ParameterKey, .ParameterValue] | "\(.[0])=\(.[1])"' "clusters/${CLUSTER}/deploy-aws-roles-anywhere-parameters.json") \
        --capabilities CAPABILITY_NAMED_IAM

rm "clusters/${CLUSTER}/deploy-aws-roles-anywhere-parameters.json"
