#!/usr/bin/env bash
# Generate the controlplane PKI hierarchy (M2 design amendment A5):
#
#   ryezone-labs Root CA            10y, offline — key exists ONLY
#                                   SOPS-encrypted in this repo
#   └─ ryezone-labs Intermediate CA controlplane
#                                   1y, maxPathLen=1 — step-ca issuing pair
#                                   AND cert-manager ClusterIssuer CA
#
# Run by a HUMAN (M2 execution step 2). Produces:
#   clusters/controlplane/secrets/step-ca-root.sops.yaml        (whole-file enc)
#   clusters/controlplane/resources/step-ca-intermediate.sops.yaml
#       Secret csi-driver-spiffe-ca, ns cert-manager (data-only enc)
#   clusters/controlplane/resources/step-ca-root-cert.yaml
#       ConfigMap with the PUBLIC root cert (plain — public material)
# and pins STEP_CA_ROOT_FINGERPRINT in tests/platform-baseline/values/controlplane.env.
#
# SOPS note: encryption bypasses creation-rule discovery on purpose
# (rules match the plaintext INPUT path — docs/memory/sops-creation-rule-input-path.md).
# Recipients are read from clusters/controlplane/.sops.yaml and passed with
# --age explicitly; every output is asserted to contain ENC[ before the
# script succeeds. Plaintext keys only ever exist inside a mktemp dir that
# is shredded on exit.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_DIR="${REPO}/clusters/controlplane"
VALUES_FILE="${REPO}/tests/platform-baseline/values/controlplane.env"
STEP="${REPO}/.venv/bin/step"

ROOT_OUT="${CLUSTER_DIR}/secrets/step-ca-root.sops.yaml"
INT_OUT="${CLUSTER_DIR}/resources/step-ca-intermediate.sops.yaml"
ROOT_CERT_OUT="${CLUSTER_DIR}/resources/step-ca-root-cert.yaml"

ROOT_CN="ryezone-labs Root CA"
INT_CN="ryezone-labs Intermediate CA controlplane"
ROOT_NOT_AFTER="87600h"   # 10 years
INT_NOT_AFTER="8760h"     # 1 year

info()  { echo "[INFO]  $*"; }
fatal() { echo "[ERROR] $*" >&2; exit 1; }

[ -x "${STEP}" ] || "${REPO}/.bin/install-step.sh"
[ -x "${STEP}" ] || fatal "step CLI not available at ${STEP}"
command -v sops >/dev/null || fatal "sops not on PATH (.bin/install-sops.sh)"

if [ -f "${ROOT_OUT}" ] && [ "${1:-}" != "--force" ]; then
    fatal "root material already exists at ${ROOT_OUT} — regenerating the root re-anchors fleet trust. Pass --force only for a deliberate root ceremony."
fi

# Recipients from the cluster's .sops.yaml (all rules share the key).
AGE_RECIPIENTS="$(grep -o 'age1[a-z0-9]*' "${CLUSTER_DIR}/.sops.yaml" | sort -u | paste -sd, -)"
[ -n "${AGE_RECIPIENTS}" ] || fatal "no age recipients found in ${CLUSTER_DIR}/.sops.yaml"
info "age recipients: ${AGE_RECIPIENTS}"

umask 077
TMP="$(mktemp -d)"
cleanup() {
    # Best-effort shred of key material before removal.
    find "${TMP}" -type f -exec sh -c 'dd if=/dev/urandom of="$1" bs=1k count=4 conv=notrunc 2>/dev/null || true' _ {} \;
    rm -rf "${TMP}"
}
trap cleanup EXIT

# --- Generate ---------------------------------------------------------------
# maxPathLen -1 = no path length constraint. Omitting it (or using
# --profile root-ca) yields pathlen:0 / pathlen:1 respectively — both break
# the M4 chain root → controlplane int (pathlen:1) → workload int → leaf.
# Verified empirically against step CLI templates, 2026-07-13.
cat > "${TMP}/root.tpl" <<'EOF'
{
  "subject": {{ toJson .Subject }},
  "issuer": {{ toJson .Subject }},
  "keyUsage": ["certSign", "crlSign"],
  "basicConstraints": {"isCA": true, "maxPathLen": -1}
}
EOF
cat > "${TMP}/intermediate.tpl" <<'EOF'
{
  "subject": {{ toJson .Subject }},
  "keyUsage": ["certSign", "crlSign"],
  "basicConstraints": {"isCA": true, "maxPathLen": 1}
}
EOF

info "generating root (${ROOT_NOT_AFTER})"
"${STEP}" certificate create "${ROOT_CN}" "${TMP}/root.crt" "${TMP}/root.key" \
    --template "${TMP}/root.tpl" --not-after "${ROOT_NOT_AFTER}" \
    --no-password --insecure

info "generating intermediate (${INT_NOT_AFTER}, maxPathLen=1)"
"${STEP}" certificate create "${INT_CN}" "${TMP}/intermediate.crt" "${TMP}/intermediate.key" \
    --template "${TMP}/intermediate.tpl" --not-after "${INT_NOT_AFTER}" \
    --ca "${TMP}/root.crt" --ca-key "${TMP}/root.key" \
    --no-password --insecure

FINGERPRINT="$("${STEP}" certificate fingerprint "${TMP}/root.crt")"
ROOT_NOT_AFTER_DATE="$(openssl x509 -enddate -noout -in "${TMP}/root.crt" | sed 's/notAfter=//')"
INT_NOT_AFTER_DATE="$(openssl x509 -enddate -noout -in "${TMP}/intermediate.crt" | sed 's/notAfter=//')"
info "root fingerprint: ${FINGERPRINT}"
info "root notAfter:    ${ROOT_NOT_AFTER_DATE}"
info "int  notAfter:    ${INT_NOT_AFTER_DATE}"

# Sanity: verify chain + path length constraints before anything is written
# to the repo. The root must be UNconstrained (no pathlen) or the M4
# workload-intermediate chain breaks.
"${STEP}" certificate verify "${TMP}/intermediate.crt" --roots "${TMP}/root.crt" \
    || fatal "intermediate does not verify against root"
openssl x509 -text -noout -in "${TMP}/root.crt" | grep -A1 'Basic Constraints' | grep -q 'pathlen' \
    && fatal "root carries a pathlen constraint — must be unconstrained"
openssl x509 -text -noout -in "${TMP}/intermediate.crt" | grep -q 'pathlen:1' \
    || fatal "intermediate is missing pathlen:1"

# --- Encrypt + write --------------------------------------------------------
enc() { # enc <plain-yaml> <target> [--data-only]
    local plain="$1" target="$2" mode="${3:-}"
    if [ "${mode}" = "--data-only" ]; then
        sops --config /dev/null -e --age "${AGE_RECIPIENTS}" \
            --encrypted-regex '^(data|stringData)$' "${plain}" > "${target}"
    else
        sops --config /dev/null -e --age "${AGE_RECIPIENTS}" "${plain}" > "${target}"
    fi
    grep -q 'ENC\[' "${target}" || { rm -f "${target}"; fatal "encryption produced no ENC[ markers for ${target} — aborting"; }
}

# Root key material: whole-file encrypted, never applied to a cluster.
{
    echo "description: ryezone-labs Root CA — OFFLINE key material (M2 design A5). Never apply to a cluster; decrypt only for an intermediate-issuance ceremony."
    echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "notAfter: ${ROOT_NOT_AFTER_DATE}"
    echo "fingerprintSHA256: ${FINGERPRINT}"
    echo "root.crt: |"
    sed 's/^/  /' "${TMP}/root.crt"
    echo "root.key: |"
    sed 's/^/  /' "${TMP}/root.key"
} > "${TMP}/root-material.yaml"
enc "${TMP}/root-material.yaml" "${ROOT_OUT}"
info "wrote ${ROOT_OUT}"

# Intermediate as the csi-driver-spiffe-ca Secret (name kept for wiring
# continuity — chart mounts, ESO sync, ClusterIssuer). ca.crt carries the root.
kubectl create secret generic csi-driver-spiffe-ca \
    --namespace=cert-manager \
    --type=kubernetes.io/tls \
    --from-file=tls.crt="${TMP}/intermediate.crt" \
    --from-file=tls.key="${TMP}/intermediate.key" \
    --from-file=ca.crt="${TMP}/root.crt" \
    --dry-run=client -o yaml \
    | kubectl annotate --local -f - -o yaml \
        'ignore-check.kube-linter.io/schema-validation=SOPS-encrypted secret; top-level sops field is expected and non-standard by design' \
    > "${TMP}/intermediate-secret.yaml"
enc "${TMP}/intermediate-secret.yaml" "${INT_OUT}" --data-only
info "wrote ${INT_OUT}"

# Public root cert: plain ConfigMap (public material, no encryption).
kubectl create configmap step-ca-root-ca \
    --namespace=cert-manager \
    --from-file=root.crt="${TMP}/root.crt" \
    --dry-run=client -o yaml > "${ROOT_CERT_OUT}"
info "wrote ${ROOT_CERT_OUT}"

# --- Pin the fingerprint in the acceptance-gate values file -----------------
if grep -q '^STEP_CA_ROOT_FINGERPRINT=SET-AT-M2-STEP-2$' "${VALUES_FILE}"; then
    sed -i '' "s/^STEP_CA_ROOT_FINGERPRINT=SET-AT-M2-STEP-2$/STEP_CA_ROOT_FINGERPRINT=${FINGERPRINT}/" "${VALUES_FILE}"
    info "pinned fingerprint in ${VALUES_FILE}"
else
    echo "[WARN]  ${VALUES_FILE} placeholder not found — set STEP_CA_ROOT_FINGERPRINT=${FINGERPRINT} manually"
fi

# Decrypt round-trip if the private key is available locally.
if [ -f "${CLUSTER_DIR}/.sops.age-key" ]; then
    SOPS_AGE_KEY_FILE="${CLUSTER_DIR}/.sops.age-key" sops -d "${ROOT_OUT}" > /dev/null \
        && info "decrypt round-trip OK" \
        || fatal "decrypt round-trip FAILED for ${ROOT_OUT}"
fi

echo ""
info "done. Next steps:"
info "  1. Store a copy of the root fingerprint + this run's output in 1Password (vault: controlplane)."
info "  2. Commit ${ROOT_OUT#"${REPO}"/}, ${INT_OUT#"${REPO}"/}, ${ROOT_CERT_OUT#"${REPO}"/}, and the values file."
info "  3. Wiring into clusters/controlplane/kustomization.yaml happens with the step-ca variant (M2 step 3/4) — do not add these resources before cert-manager's namespace exists."
