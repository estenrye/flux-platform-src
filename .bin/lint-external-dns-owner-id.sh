#!/bin/bash
# Render lint: for each cluster directory given, render it with kustomize and
# assert that every external-dns container using the TXT registry (the
# default; i.e. anything but --registry=noop) sets a non-empty --txt-owner-id.
# Without one, external-dns uses the owner "default" and every cluster that
# syncs against a shared DNS zone deletes the others' records each interval
# (confirmed 2026-10-24: see clusters/core-infra/patches/external-dns.txt-owner-id.yaml).
# --registry=noop writes no ownership records, so it is exempt. Only the
# --flag=value arg form is recognised (what the chart renders).
# A clean kustomize build proves nothing here: a JSON6902 patch whose target
# matches nothing is a silent no-op (docs/memory/m3-render-lint-ci-fix.md).
# A cluster that renders no external-dns passes.
set -euo pipefail

[ "$#" -gt 0 ] || { echo "Usage: $0 <cluster-dir>..." >&2; exit 2; }

FAIL=0
for dir in "$@"; do
  rendered=$(kustomize build --enable-helm --helm-kube-version 1.36.2 "${dir}")

  # One line per workload with an external-dns container that uses the TXT
  # registry but has no owner id: <kind>/<namespace>/<name>
  # (No `. as $w` binding: it breaks the nested selects in this yq version.)
  bad=$(printf '%s\n' "${rendered}" | yq eval '
    select(.kind == "Deployment" or .kind == "DaemonSet" or .kind == "StatefulSet")
    | select([
        .spec.template.spec.containers[]
        | select(.name == "external-dns")
        | select(([.args[]? | select(. == "--registry=noop")] | length) == 0)
        | select(([.args[]? | select(test("^--txt-owner-id=."))] | length) == 0)
      ] | length > 0)
    | .kind + "/" + .metadata.namespace + "/" + .metadata.name' - | grep -v '^---$' || true)

  if [ -n "${bad}" ]; then
    while read -r resource; do
      echo "FAIL: ${dir}: ${resource} uses the TXT registry without --txt-owner-id"
      FAIL=$((FAIL + 1))
    done <<< "${bad}"
  else
    echo "OK:   ${dir}: external-dns owner ids valid"
  fi
done

[ "${FAIL}" -eq 0 ]
