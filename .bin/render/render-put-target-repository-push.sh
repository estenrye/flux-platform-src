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

BRANCH_NAME="rendered/${SOURCE_REPO_OWNER}/${SOURCE_REPO_NAME}/${SOURCE_REPO_BRANCH}"
echo "Creating Branch: ${BRANCH_NAME}"

pushd ${RENDER_DIR}/${TARGET_REPO_NAME} > /dev/null || exit 1
GIT_USER_NAME="$(git config --get user.name 2>/dev/null || true)"
GIT_USER_EMAIL="$(git config --get user.email 2>/dev/null || true)"

if [ -z "${GIT_USER_NAME}" ]; then
  GIT_USER_NAME="${RENDER_GIT_USER_NAME:-}"
fi

if [ -z "${GIT_USER_EMAIL}" ]; then
  GIT_USER_EMAIL="${RENDER_GIT_USER_EMAIL:-}"
fi

if [ -z "${GIT_USER_NAME}" ] || [ -z "${GIT_USER_EMAIL}" ]; then
  echo "Missing git author identity. Set git config user.name/user.email or provide RENDER_GIT_USER_NAME/RENDER_GIT_USER_EMAIL." >&2
  exit 1
fi

git config user.name "${GIT_USER_NAME}"
git config user.email "${GIT_USER_EMAIL}"

if [ -n "${RENDER_GITHUB_TOKEN:-}" ]; then
  git config --local credential.helper store
  echo "https://x-access-token:${RENDER_GITHUB_TOKEN}@github.com" > ~/.git-credentials
  chmod 600 ~/.git-credentials
fi

git add .
git commit \
  -m "Render ${SOURCE_REPO_NAME}/${SOURCE_REPO_BRANCH}" \
  -m "Commit: ${SOURCE_REPO_COMMIT_HASH}"
git push origin ${BRANCH_NAME}
popd > /dev/null || exit 1