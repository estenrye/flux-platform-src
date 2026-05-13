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

BRANCH_NAME="rendered/${SOURCE_REPO_OWNER}/${SOURCE_REPO_NAME}/${SOURCE_REPO_BRANCH}"
PR_TITLE=${PR_TITLE:-"Render ${SOURCE_REPO_NAME}/${SOURCE_REPO_BRANCH}"}
SOURCE_COMMIT_URL="https://github.com/${SOURCE_REPO_OWNER}/${SOURCE_REPO_NAME}/commit/${SOURCE_REPO_COMMIT_HASH}"
SOURCE_COMMIT_LABEL="${SOURCE_REPO_OWNER}/${SOURCE_REPO_NAME}@${SOURCE_REPO_COMMIT_HASH:0:12}"

export GH_TOKEN

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI is required to create the target repository pull request." >&2
  exit 1
fi

generate_copilot_summary() {
  local prompt

  prompt=$(cat <<EOF
Summarize the rendered changes in this repository for a pull request body.
Use only the current git diff versus origin/${TARGET_REPO_BASE_BRANCH}.
Return markdown only as 3 to 6 concise bullet points.
Do not include a title, intro sentence, code fences, or the source commit link.
EOF
)

  gh copilot -p "${prompt}" --allow-tool 'shell(git)'
}

echo "Creating Pull Request for branch: ${BRANCH_NAME}"

pushd "${RENDER_DIR}/${TARGET_REPO_NAME}" > /dev/null || exit 1
git fetch origin "${TARGET_REPO_BASE_BRANCH}" --depth 1

PR_BODY_FILE=$(mktemp)
cleanup() {
  rm -f "${PR_BODY_FILE}"
}
trap cleanup EXIT

COPILOT_SUMMARY=$(generate_copilot_summary)

{
  printf 'Source commit: [%s](%s)\n\n' "${SOURCE_COMMIT_LABEL}" "${SOURCE_COMMIT_URL}"
  printf '%s\n' "${COPILOT_SUMMARY}"
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
  gh pr view "${EXISTING_PR_NUMBER}" --repo "${TARGET_REPO_OWNER}/${TARGET_REPO_NAME}" --json url --jq '.url'
else
  gh pr create \
    --repo "${TARGET_REPO_OWNER}/${TARGET_REPO_NAME}" \
    --base "${TARGET_REPO_BASE_BRANCH}" \
    --head "${BRANCH_NAME}" \
    --title "${PR_TITLE}" \
    --body-file "${PR_BODY_FILE}"
fi

popd > /dev/null || exit 1