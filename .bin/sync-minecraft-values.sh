#!/bin/bash
# Kustomize refuses a Helm values file outside the overlay root, so the shared
# applications/minecraft/base/values.yaml is stamped into each instance as
# <instance>/base.values.yaml (substituting __INSTANCE__ and __ZONE__).
# Run without args to regenerate; with --check to fail on drift (CI/lint).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)/applications/minecraft"

# instance:dns-zone
INSTANCES=(
  arrendelle-winter:rye.ninja
  arrendelle-winter-dev:rye.ninja
  baked-goods:citsell.com
  bakery:rye.ninja
  family-minecraft:rye.ninja
  mermaid-cove:rye.ninja
  mermaid-cove-dev:rye.ninja
  pokehaan-craft:rye.ninja
)

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

FAIL=0
for entry in "${INSTANCES[@]}"; do
  instance="${entry%%:*}"
  zone="${entry#*:}"
  out="${ROOT}/${instance}/base.values.yaml"
  rendered=$(sed -e "s/__INSTANCE__/${instance}/g" -e "s/__ZONE__/${zone}/g" "${ROOT}/base/values.yaml")
  if [ "${CHECK}" -eq 1 ]; then
    if [ "$(cat "${out}" 2>/dev/null)" != "${rendered}" ]; then
      echo "FAIL: ${out} is stale; run .bin/sync-minecraft-values.sh"
      FAIL=$((FAIL + 1))
    fi
  else
    printf '%s\n' "${rendered}" > "${out}"
  fi
done

[ "${FAIL}" -eq 0 ]
