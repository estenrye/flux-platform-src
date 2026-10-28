#!/bin/bash
# Render lint: for each cluster directory given, render it with kustomize and
# assert that, when grafana is present, its Gateway listener, HTTPRoute and
# grafana-site ConfigMap no longer carry the base's placeholders
# (grafana.k8s.local, JUMPCLOUD_OIDC_PKCE_CLIENT_ID). Each cluster must patch
# all three (see clusters/core-infra/patches/grafana.*). A clean kustomize
# build proves none of it: a JSON6902 patch whose target matches nothing is a
# silent no-op (docs/memory/m3-render-lint-ci-fix.md).
# A cluster that renders no grafana resources passes.
set -euo pipefail

HOST_PLACEHOLDER="grafana.k8s.local"
CLIENT_PLACEHOLDER="JUMPCLOUD_OIDC_PKCE_CLIENT_ID"

[ "$#" -gt 0 ] || { echo "Usage: $0 <cluster-dir>..." >&2; exit 2; }

FAIL=0
for dir in "$@"; do
  rendered=$(kustomize build --enable-helm --helm-kube-version 1.36.2 "${dir}")

  # One line per offending resource: <kind>/<name>: <what>
  bad=$(printf '%s\n' "${rendered}" | yq eval '
    select(.metadata.namespace == "grafana")
    | (select(.kind == "HTTPRoute")
        | select(.spec.hostnames[]? == "'"${HOST_PLACEHOLDER}"'")
        | .kind + "/" + .metadata.name + " still uses placeholder hostname '"${HOST_PLACEHOLDER}"'"),
      (select(.kind == "Gateway")
        | select(.spec.listeners[]?.hostname == "'"${HOST_PLACEHOLDER}"'")
        | .kind + "/" + .metadata.name + " still uses placeholder hostname '"${HOST_PLACEHOLDER}"'"),
      (select(.kind == "ConfigMap" and .metadata.name == "grafana-site")
        | select(.data.GF_SERVER_ROOT_URL == "https://'"${HOST_PLACEHOLDER}"'")
        | .kind + "/" + .metadata.name + " still uses placeholder GF_SERVER_ROOT_URL"),
      (select(.kind == "ConfigMap" and .metadata.name == "grafana-site")
        | select(.data.GF_AUTH_GENERIC_OAUTH_CLIENT_ID == "'"${CLIENT_PLACEHOLDER}"'")
        | .kind + "/" + .metadata.name + " still uses placeholder GF_AUTH_GENERIC_OAUTH_CLIENT_ID")' - | grep -v '^---$' || true)

  if [ -n "${bad}" ]; then
    while read -r line; do
      echo "FAIL: ${dir}: ${line}"
      FAIL=$((FAIL + 1))
    done <<< "${bad}"
  else
    echo "OK:   ${dir}: grafana placeholders patched"
  fi
done

[ "${FAIL}" -eq 0 ]
