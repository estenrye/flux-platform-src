#!/bin/bash
set -euo pipefail
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}
BASE_DIR=${BASE_DIR:-$(dirname "$SCRIPTS_DIR")}
CLUSTER=${CLUSTER:?CLUSTER is required. Usage: make bootstrap-cluster-environment CLUSTER=<cluster-dir-name>}
SOURCE_REPO=${SOURCE_REPO:-estenrye/flux-platform-src}

CATALOG="${BASE_DIR}/clusters/${CLUSTER}/catalog.yaml"
[ -f "${CATALOG}" ] || { echo "Error: ${CATALOG} not found"; exit 1; }

ENV_NAME=$(yq e '.metadata.name' "${CATALOG}")
[ -n "${ENV_NAME}" ] && [ "${ENV_NAME}" != "null" ] || {
  echo "Error: metadata.name is missing or null in ${CATALOG}"; exit 1
}

echo "Creating GitHub Environment '${ENV_NAME}' in ${SOURCE_REPO} ..."

gh api --method PUT \
  -H "Accept: application/vnd.github+json" \
  "/repos/${SOURCE_REPO}/environments/${ENV_NAME}" \
  --input - <<'EOF'
{}
EOF

# Deployment branch policies require GitHub Team/Enterprise plan.
# Try to restrict to 'main'; warn and continue if the plan doesn't support it.
echo "Attempting to restrict deployments to 'main' branch ..."
if gh api --method PUT \
    -H "Accept: application/vnd.github+json" \
    "/repos/${SOURCE_REPO}/environments/${ENV_NAME}" \
    --input - 2>/dev/null <<'EOF'
{
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  }
}
EOF
then
  EXISTING=$(gh api "/repos/${SOURCE_REPO}/environments/${ENV_NAME}/deployment-branch-policies" \
    --jq '[.branch_policies[].name] | index("main")' 2>/dev/null || echo "null")
  if [ "${EXISTING}" = "null" ]; then
    gh api --method POST \
      -H "Accept: application/vnd.github+json" \
      "/repos/${SOURCE_REPO}/environments/${ENV_NAME}/deployment-branch-policies" \
      -f name="main" \
      -f type="branch"
  else
    echo "Branch policy for 'main' already exists — skipping."
  fi
else
  echo "Warning: could not set deployment branch policy (requires GitHub Team/Enterprise plan)."
  echo "Environment will work but is not restricted to the 'main' branch."
fi

echo ""
echo "Environment created. Current configuration:"
gh api "/repos/${SOURCE_REPO}/environments/${ENV_NAME}" \
  --jq '{name: .name, deployment_branch_policy: .deployment_branch_policy, protection_rules: [.protection_rules[].type]}'
