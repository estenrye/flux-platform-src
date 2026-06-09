#!/bin/bash
set -euo pipefail
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
SOURCE_PR_NUMBER=${SOURCE_PR_NUMBER:?SOURCE_PR_NUMBER is required}
RENDERED_PRS_DIR=${RENDERED_PRS_DIR:?RENDERED_PRS_DIR is required}
SOURCE_REPO=${SOURCE_REPO:-$(bash "${SCRIPTS_DIR}/render/render-get-source-repository.sh")}
GH_TOKEN=${GITHUB_TOKEN:-$(gh auth token)}
export GH_TOKEN

START_MARKER='<!-- rendered-prs-start -->'
END_MARKER='<!-- rendered-prs-end -->'

# Build table rows from per-cluster artifact files
rows=""
for file in "${RENDERED_PRS_DIR}"/*.txt; do
  [ -f "${file}" ] || continue
  content=$(tr -d '\n' < "${file}")
  cluster="${content%%|*}"
  pr_url="${content##*|}"
  pr_number=$(echo "${pr_url}" | grep -oE '[0-9]+$')
  rows="${rows}| ${cluster} | [#${pr_number} Render](${pr_url}) |\n"
done

body_file=$(mktemp)
new_body_file=$(mktemp)
section_file=$(mktemp)
cleanup() { rm -f "${body_file}" "${section_file}"; }
trap cleanup EXIT

# Write the new section to a file (avoids quoting issues in Python)
printf '%s\n## Rendered PRs\n\n| Cluster | PR |\n|---------|---|\n%b%s\n' \
  "${START_MARKER}" "${rows}" "${END_MARKER}" > "${section_file}"

# Get current PR body
gh pr view "${SOURCE_PR_NUMBER}" \
  --repo "${SOURCE_REPO}" \
  --json body \
  --jq '.body' > "${body_file}"

# Replace or append section using Python for reliable multiline handling
python3 - "${body_file}" "${section_file}" "${new_body_file}" <<'PYEOF'
import sys

body_path, section_path, output_path = sys.argv[1:]

with open(body_path) as f:
    body = f.read()

with open(section_path) as f:
    section = f.read().rstrip('\n')

start = '<!-- rendered-prs-start -->'
end = '<!-- rendered-prs-end -->'

if start in body:
    pre = body[:body.index(start)]
    post_start = body.index(end) + len(end)
    post = body[post_start:]
    new_body = pre + section + post
else:
    new_body = body.rstrip() + '\n\n' + section + '\n'

with open(output_path, 'w') as f:
    f.write(new_body)
PYEOF

gh pr edit "${SOURCE_PR_NUMBER}" \
  --repo "${SOURCE_REPO}" \
  --body-file "${new_body_file}"
