#!/bin/bash
set -euo pipefail

SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
RENDER_DIR=${RENDER_DIR:-$(dirname "$SCRIPTS_DIR")/.render}
TARGET_REPO_NAME=${TARGET_REPO_NAME:-flux-platform-rendered}

find "${RENDER_DIR}/${TARGET_REPO_NAME}" -name "rendered.yaml" | while read -r rendered_file; do
  parent_dir=$(dirname "${rendered_file}")

  python3 - "${rendered_file}" "${parent_dir}" <<'PYEOF'
import sys, os, re, yaml

rendered_file = sys.argv[1]
parent_dir = sys.argv[2]

with open(rendered_file, 'r') as f:
    content = f.read()

# Split on YAML document separator, preserving raw content
raw_docs = re.split(r'^---[ \t]*$', content, flags=re.MULTILINE)
raw_docs = [d.strip() for d in raw_docs if d.strip()]

resource_files = []

for raw_doc in raw_docs:
    doc = yaml.safe_load(raw_doc)
    if doc is None:
        continue

    api_version = doc.get('apiVersion', '')
    kind = doc.get('kind', '')
    metadata = doc.get('metadata', {})
    name = metadata.get('name', 'unknown')
    namespace = metadata.get('namespace')

    # Split apiVersion into group and version
    if '/' in api_version:
        api_group, api_ver = api_version.rsplit('/', 1)
    else:
        api_group = None
        api_ver = api_version

    kind_lower = kind.lower()

    # Sanitize name: colons and other filesystem-invalid chars break artifact uploads
    safe_name = re.sub(r'[:"<>|*?\r\n]', '_', name)

    # Build filename: omit apiGroup for core API resources (no group)
    if api_group:
        filename = f"{api_group}_{api_ver}_{kind_lower}_{safe_name}.yaml"
    else:
        filename = f"{api_ver}_{kind_lower}_{safe_name}.yaml"

    # Namespaced vs cluster-scoped path
    if namespace:
        rel_path = f"resources/{namespace}/{filename}"
    else:
        rel_path = f"resources/{filename}"

    output_path = os.path.join(parent_dir, rel_path)
    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    with open(output_path, 'w') as f:
        f.write(raw_doc)
        f.write('\n')

    resource_files.append(rel_path)

# Sort for deterministic diffs
resource_files.sort()

# Write kustomization.yaml listing every resource file explicitly
kustomization_lines = [
    'apiVersion: kustomize.config.k8s.io/v1beta1',
    'kind: Kustomization',
    'resources:',
]
for p in resource_files:
    kustomization_lines.append(f'- {p}')

with open(os.path.join(parent_dir, 'kustomization.yaml'), 'w') as f:
    f.write('\n'.join(kustomization_lines) + '\n')

os.remove(rendered_file)
print(f"Split {len(resource_files)} resources from {rendered_file}")
PYEOF
done
