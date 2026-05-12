#!/bin/bash
set -e
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
RENDER_DIR=${RENDER_DIR:-$(cd "$(dirname "$SCRIPTS_DIR")/.render" && pwd)}
SOURCE_REPO_OWNER=${SOURCE_REPO_OWNER:-$(${SCRIPTS_DIR}/render/render-get-source-repository-owner.sh)}
SOURCE_REPO_NAME=${SOURCE_REPO_NAME:-$(${SCRIPTS_DIR}/render/render-get-source-repository-name.sh)}
SOURCE_REPO_BRANCH=${SOURCE_REPO_BRANCH:-$(${SCRIPTS_DIR}/render/render-get-source-repository-branch.sh)}
SOURCE_REPO_COMMIT_HASH=`${SCRIPTS_DIR}/render/render-get-source-repository-commit-hash.sh`
TARGET_REPO_OWNER=${TARGET_REPO_OWNER:-$(${SCRIPTS_DIR}/render/render-get-source-repository-owner.sh)}
TARGET_REPO_NAME=${TARGET_REPO_NAME:-flux-platform-rendered}
GH_TOKEN=${RENDER_GITHUB_TOKEN:-$(gh auth token)}

resolve_git_identity_from_pr_creator() {
  local repo
  local sha
  local pr_author_login
  local pr_author_id
  local pr_author_name

  repo="${GITHUB_REPOSITORY:-${SOURCE_REPO_OWNER}/${SOURCE_REPO_NAME}}"
  sha="${GITHUB_SHA:-${SOURCE_REPO_COMMIT_HASH}}"

  if ! command -v gh >/dev/null 2>&1; then
    return 1
  fi

  pr_author_login=$(GH_TOKEN="${GH_TOKEN}" gh api \
    -H "Accept: application/vnd.github+json" \
    "/repos/${repo}/commits/${sha}/pulls" \
    --jq '.[0].user.login' 2>/dev/null || true)

  pr_author_id=$(GH_TOKEN="${GH_TOKEN}" gh api \
    -H "Accept: application/vnd.github+json" \
    "/repos/${repo}/commits/${sha}/pulls" \
    --jq '.[0].user.id' 2>/dev/null || true)

  if [ -z "${pr_author_login}" ] || [ "${pr_author_login}" = "null" ]; then
    return 1
  fi

  pr_author_name=$(GH_TOKEN="${GH_TOKEN}" gh api \
    -H "Accept: application/vnd.github+json" \
    "/users/${pr_author_login}" \
    --jq '.name' 2>/dev/null || true)

  if [ -z "${pr_author_name}" ] || [ "${pr_author_name}" = "null" ]; then
    pr_author_name="${pr_author_login}"
  fi

  if [ -z "${pr_author_id}" ] || [ "${pr_author_id}" = "null" ]; then
    return 1
  fi

  GIT_USER_NAME="${pr_author_name}"
  GIT_USER_EMAIL="${pr_author_id}+${pr_author_login}@users.noreply.github.com"
  return 0
}

BRANCH_NAME="rendered/${SOURCE_REPO_OWNER}/${SOURCE_REPO_NAME}/${SOURCE_REPO_BRANCH}"
echo "Creating Branch: ${BRANCH_NAME}"

pushd ${RENDER_DIR}/${TARGET_REPO_NAME} > /dev/null || exit 1
GIT_USER_NAME="${RENDER_GIT_USER_NAME:-$(git config --get user.name 2>/dev/null || true)}"
GIT_USER_EMAIL="${RENDER_GIT_USER_EMAIL:-$(git config --get user.email 2>/dev/null || true)}"

if [ -z "${GIT_USER_NAME}" ] || [ -z "${GIT_USER_EMAIL}" ]; then
  if ! resolve_git_identity_from_pr_creator; then
    GIT_USER_NAME="${GITHUB_ACTOR:-github-actions[bot]}"
    GIT_USER_EMAIL="${GITHUB_ACTOR:-github-actions[bot]}@users.noreply.github.com"
  fi
fi

echo "Using git author: ${GIT_USER_NAME} <${GIT_USER_EMAIL}>"
git config user.name "${GIT_USER_NAME}"
git config user.email "${GIT_USER_EMAIL}"

git add .
git commit \
  -m "Render ${SOURCE_REPO_NAME}/${SOURCE_REPO_BRANCH}" \
  -m "Commit: ${SOURCE_REPO_COMMIT_HASH}"
git push origin ${BRANCH_NAME}
popd > /dev/null || exit 1