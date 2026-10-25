#!/bin/bash
# Render lint: for each cluster directory given, render it with kustomize and
# assert that, when netdata is present, neither its Gateway listener nor its
# HTTPRoute still carries the base's placeholder hostname netdata.k8s.local.
# Each cluster must patch both (see clusters/core-infra/patches/netdata.*).
# A clean kustomize build proves neither: a JSON6902 patch whose target
# matches nothing is a silent no-op (docs/memory/m3-render-lint-ci-fix.md).
# A cluster that renders no netdata Gateway/HTTPRoute passes.
set -euo pipefail

PLACEHOLDER="netdata.k8s.local"

[ "$#" -gt 0 ] || { echo "Usage: $0 <cluster-dir>..." >&2; exit 2; }

FAIL=0
for dir in "$@"; do
  rendered=$(kustomize build --enable-helm --helm-kube-version 1.36.2 "${dir}")

  # One line per offending resource: <kind>/<name>
  bad=$(printf '%s\n' "${rendered}" | yq eval '
    select(.metadata.namespace == "netdata")
    | (select(.kind == "HTTPRoute" and .metadata.name == "netdata")
        | select(.spec.hostnames[]? == "'"${PLACEHOLDER}"'")
        | .kind + "/" + .metadata.name),
      (select(.kind == "Gateway" and .metadata.name == "netdata-gateway")
        | select(.spec.listeners[]?.hostname == "'"${PLACEHOLDER}"'")
        | .kind + "/" + .metadata.name)' - | grep -v '^---$' || true)

  if [ -n "${bad}" ]; then
    while read -r resource; do
      echo "FAIL: ${dir}: ${resource} still uses placeholder hostname ${PLACEHOLDER}"
      FAIL=$((FAIL + 1))
    done <<< "${bad}"
  else
    echo "OK:   ${dir}: netdata hostnames valid"
  fi
done

[ "${FAIL}" -eq 0 ]
