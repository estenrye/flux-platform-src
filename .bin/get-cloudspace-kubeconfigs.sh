#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/lib/prompt-color.sh"

for catalog in "${REPO_ROOT}"/clusters/*/catalog.yaml; do
  org=$(yq e '.metadata.annotations["rye.ninja/spot-org"]' "${catalog}")
  name=$(yq e '.metadata.annotations["rye.ninja/spot-cloudspace-name"]' "${catalog}")

  if [ "${org}" = "null" ] || [ -z "${org}" ] || [ "${name}" = "null" ] || [ -z "${name}" ]; then
    warn "Skipping ${catalog}: missing spot-org or spot-cloudspace-name annotation"
    continue
  fi

  out_dir="${HOME}/.kube/spot/${org}"
  out="${out_dir}/${name}.yaml"
  mkdir -p "${out_dir}"

  info "Fetching kubeconfig for ${name} (org: ${org}) → ${out}"
  "${SCRIPT_DIR}/../.venv/bin/spotctl" cloudspaces get-config \
    --name "${name}" \
    --org "${org}" \
    --file "${out_dir}"
  success "Saved ${out}"
done
