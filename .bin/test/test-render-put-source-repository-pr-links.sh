#!/bin/bash
set -e
SCRIPTS_DIR=$(cd "$(dirname "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d)
trap "rm -rf ${TEMP_DIR}" EXIT

GH_CALLS_FILE="${TEMP_DIR}/gh_calls.txt"
touch "${GH_CALLS_FILE}"

# Mock gh to capture calls
mkdir -p "${TEMP_DIR}/bin"
cat > "${TEMP_DIR}/bin/gh" <<MOCK
#!/bin/bash
echo "\$@" >> "${GH_CALLS_FILE}"
if echo "\$@" | grep -q -- "--json body"; then
  echo "Fixes a bug in the app."
fi
MOCK
chmod +x "${TEMP_DIR}/bin/gh"

# Setup rendered PR URL artifacts
mkdir -p "${TEMP_DIR}/rendered-prs"
printf 'spot.us-central-dfw-2.test.crossplane|https://github.com/estenrye/flux-platform-rendered-spot.us-central-dfw-2.test.crossplane/pull/7' \
  > "${TEMP_DIR}/rendered-prs/spot.us-central-dfw-2.test.crossplane.txt"

PATH="${TEMP_DIR}/bin:${PATH}" \
SOURCE_PR_NUMBER="42" \
SOURCE_REPO="estenrye/flux-platform-src" \
RENDERED_PRS_DIR="${TEMP_DIR}/rendered-prs" \
bash "${SCRIPTS_DIR}/render/render-put-source-repository-pr-links.sh"

# Verify gh pr edit was called with a body-file
EDIT_CALL=$(grep "pr edit" "${GH_CALLS_FILE}" || true)
[ -n "${EDIT_CALL}" ] || { echo "FAIL: gh pr edit was not called"; cat "${GH_CALLS_FILE}"; exit 1; }
echo "${EDIT_CALL}" | grep -q "body-file" || { echo "FAIL: gh pr edit called without --body-file"; exit 1; }

# Verify the body file used in the edit contains the rendered PR link
BODY_FILE_PATH=$(echo "${EDIT_CALL}" | grep -oE '\-\-body-file [^ ]+' | cut -d' ' -f2)
[ -f "${BODY_FILE_PATH}" ] && grep -q "rendered-prs-start" "${BODY_FILE_PATH}" || \
  { echo "FAIL: body file does not contain rendered-prs-start marker"; exit 1; }

echo "PASS: render-put-source-repository-pr-links"
