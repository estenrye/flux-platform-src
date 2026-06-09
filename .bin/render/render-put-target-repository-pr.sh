#!/bin/bash
set -euo pipefail

SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
RENDER_DIR=${RENDER_DIR:-$(cd "$(dirname "$SCRIPTS_DIR")/.render" && pwd)}
SOURCE_REPO_OWNER=${SOURCE_REPO_OWNER:-$(${SCRIPTS_DIR}/render/render-get-source-repository-owner.sh)}
SOURCE_REPO_NAME=${SOURCE_REPO_NAME:-$(${SCRIPTS_DIR}/render/render-get-source-repository-name.sh)}
SOURCE_REPO_BRANCH=${SOURCE_REPO_BRANCH:-$(${SCRIPTS_DIR}/render/render-get-source-repository-branch.sh)}
SOURCE_REPO_COMMIT_HASH=${SOURCE_REPO_COMMIT_HASH:-$(${SCRIPTS_DIR}/render/render-get-source-repository-commit-hash.sh)}
TARGET_REPO_OWNER=${TARGET_REPO_OWNER:-$(${SCRIPTS_DIR}/render/render-get-source-repository-owner.sh)}
TARGET_REPO_NAME=${TARGET_REPO_NAME:-flux-platform-rendered}
TARGET_REPO_BASE_BRANCH=${TARGET_REPO_BASE_BRANCH:-main}
GH_TOKEN=${RENDER_GITHUB_TOKEN:-${GITHUB_TOKEN:-$(gh auth token)}}
SOURCE_PR_URL=${SOURCE_PR_URL:-}
SOURCE_PR_TITLE=${SOURCE_PR_TITLE:-}
AUTO_MERGE=${AUTO_MERGE:-false}

BRANCH_NAME="rendered/${SOURCE_REPO_OWNER}/${SOURCE_REPO_NAME}/${SOURCE_REPO_BRANCH}"
PR_TITLE=${PR_TITLE:-"Render ${SOURCE_REPO_NAME}/${SOURCE_REPO_BRANCH}"}
SOURCE_COMMIT_URL="https://github.com/${SOURCE_REPO_OWNER}/${SOURCE_REPO_NAME}/commit/${SOURCE_REPO_COMMIT_HASH}"
SOURCE_COMMIT_LABEL="${SOURCE_REPO_OWNER}/${SOURCE_REPO_NAME}@${SOURCE_REPO_COMMIT_HASH:0:12}"

export GH_TOKEN

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI is required to create the target repository pull request." >&2
  exit 1
fi

echo "Creating Pull Request for branch: ${BRANCH_NAME}"

pushd "${RENDER_DIR}/${TARGET_REPO_NAME}" > /dev/null || exit 1
git fetch origin "${TARGET_REPO_BASE_BRANCH}" --depth 1

PR_BODY_FILE=$(mktemp)
cleanup() { rm -f "${PR_BODY_FILE}"; }
trap cleanup EXIT

{
  if [ -n "${SOURCE_PR_URL}" ]; then
    SOURCE_PR_NUMBER=$(echo "${SOURCE_PR_URL}" | grep -oE '[0-9]+$')
    if [ -n "${SOURCE_PR_TITLE}" ]; then
      printf 'Source PR: [#%s %s](%s)\n' "${SOURCE_PR_NUMBER}" "${SOURCE_PR_TITLE}" "${SOURCE_PR_URL}"
    else
      printf 'Source PR: [#%s](%s)\n' "${SOURCE_PR_NUMBER}" "${SOURCE_PR_URL}"
    fi
  fi
  printf 'Source commit: [%s](%s)\n' "${SOURCE_COMMIT_LABEL}" "${SOURCE_COMMIT_URL}"
} > "${PR_BODY_FILE}"

EXISTING_PR_NUMBER=$(gh pr list \
  --repo "${TARGET_REPO_OWNER}/${TARGET_REPO_NAME}" \
  --head "${BRANCH_NAME}" \
  --state open \
  --json number \
  --jq '.[0].number // empty')

if [ -n "${EXISTING_PR_NUMBER}" ]; then
  gh pr edit "${EXISTING_PR_NUMBER}" \
    --repo "${TARGET_REPO_OWNER}/${TARGET_REPO_NAME}" \
    --title "${PR_TITLE}" \
    --body-file "${PR_BODY_FILE}"
  PR_URL=$(gh pr view "${EXISTING_PR_NUMBER}" \
    --repo "${TARGET_REPO_OWNER}/${TARGET_REPO_NAME}" \
    --json url --jq '.url')
else
  PR_URL=$(gh pr create \
    --repo "${TARGET_REPO_OWNER}/${TARGET_REPO_NAME}" \
    --base "${TARGET_REPO_BASE_BRANCH}" \
    --head "${BRANCH_NAME}" \
    --title "${PR_TITLE}" \
    --body-file "${PR_BODY_FILE}")
fi

echo "rendered_pr_url=${PR_URL}" >> "${GITHUB_OUTPUT:-/dev/null}"

if [ "${AUTO_MERGE}" = "true" ]; then
  PR_NUMBER=$(echo "${PR_URL}" | grep -oE '[0-9]+$')
  gh pr merge "${PR_NUMBER}" \
    --repo "${TARGET_REPO_OWNER}/${TARGET_REPO_NAME}" \
    --squash \
    --auto
fi

popd > /dev/null || exit 1
