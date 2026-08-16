#!/usr/bin/env bash
# Generate observability's step-ca intermediate (M4 completion step B5):
#
#   ryezone-labs Root CA                    (unchanged, offline — NOT touched
#                                             by this script)
#   └─ ryezone-labs Intermediate CA controlplane   1y, maxPathLen=1
#      └─ ryezone-labs Intermediate CA observability
#                                            1y, maxPathLen=0 — this cluster's
#                                            own step-ca issuing pair AND
#                                            cert-manager ClusterIssuer CA
#
# Unlike .bin/generate-controlplane-pki.sh, this does NOT touch the offline
# root — it signs off controlplane's already-online intermediate (the same
# key already used continuously in production to sign every SVID leaf on
# controlplane), matching the chain
# .bin/generate-controlplane-pki.sh's own comments describe as the intended
# design: root -> controlplane int (pathlen:1) -> workload int -> leaf.
#
# Run by a HUMAN (needs SOPS decrypt access to BOTH clusters' age keys).
# Produces:
#   clusters/observability/resources/step-ca-intermediate.sops.yaml
#       Secret csi-driver-spiffe-ca, ns cert-manager (data-only enc)
#   clusters/observability/resources/step-ca-root-cert.yaml
#       ConfigMap with the PUBLIC root cert (plain — public material,
#       identical content to controlplane's own copy, same root)
#
# SOPS note: encryption bypasses creation-rule discovery on purpose
# (rules match the plaintext INPUT path — docs/memory/sops-creation-rule-input-path.md).
# Recipients are read from clusters/observability/.sops.yaml and passed with
# --age explicitly; every output is asserted to contain ENC[ before the
# script succeeds. Plaintext keys only ever exist inside a mktemp dir that
# is shredded on exit.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CP_CLUSTER_DIR="${REPO}/clusters/controlplane"
CLUSTER_DIR="${REPO}/clusters/observability"
STEP="${REPO}/.venv/bin/step"

CP_INT_SOPS="${CP_CLUSTER_DIR}/resources/step-ca-intermediate.sops.yaml"
CP_ROOT_CERT="${CP_CLUSTER_DIR}/resources/step-ca-root-cert.yaml"
CP_AGE_KEY="${CP_CLUSTER_DIR}/.sops.age-key"

INT_OUT="${CLUSTER_DIR}/resources/step-ca-intermediate.sops.yaml"
ROOT_CERT_OUT="${CLUSTER_DIR}/resources/step-ca-root-cert.yaml"

INT_CN="ryezone-labs Intermediate CA observability"
INT_NOT_AFTER="8760h"   # 1 year, matching controlplane's own intermediate

info()  { echo "[INFO]  $*"; }
fatal() { echo "[ERROR] $*" >&2; exit 1; }

[ -x "${STEP}" ] || "${REPO}/.bin/install-step.sh"
[ -x "${STEP}" ] || fatal "step CLI not available at ${STEP}"
command -v sops >/dev/null || fatal "sops not on PATH (.bin/install-sops.sh)"
command -v openssl >/dev/null || fatal "openssl not on PATH"

[ -f "${CP_INT_SOPS}" ] || fatal "controlplane intermediate not found at ${CP_INT_SOPS} — run generate-controlplane-pki.sh first"
[ -f "${CP_ROOT_CERT}" ] || fatal "controlplane root cert ConfigMap not found at ${CP_ROOT_CERT}"
[ -f "${CP_AGE_KEY}" ] || fatal "controlplane SOPS age key not found at ${CP_AGE_KEY} — needed to decrypt the signing intermediate"

if [ -f "${INT_OUT}" ] && [ "${1:-}" != "--force" ]; then
    fatal "observability intermediate already exists at ${INT_OUT} — regenerating cascades a resign of every SVID on this cluster. Pass --force only for a deliberate re-issuance."
fi

# Recipients from observability's own .sops.yaml.
AGE_RECIPIENTS="$(grep -o 'age1[a-z0-9]*' "${CLUSTER_DIR}/.sops.yaml" | sort -u | paste -sd, -)"
[ -n "${AGE_RECIPIENTS}" ] || fatal "no age recipients found in ${CLUSTER_DIR}/.sops.yaml"
info "observability age recipients: ${AGE_RECIPIENTS}"

umask 077
TMP="$(mktemp -d)"
cleanup() {
    # Best-effort shred of key material before removal.
    find "${TMP}" -type f -exec sh -c 'dd if=/dev/urandom of="$1" bs=1k count=4 conv=notrunc 2>/dev/null || true' _ {} \;
    rm -rf "${TMP}"
}
trap cleanup EXIT

# --- Decrypt controlplane's intermediate (the signing CA for this op) ------
info "decrypting controlplane's intermediate (signing CA)..."
SOPS_AGE_KEY_FILE="${CP_AGE_KEY}" sops -d "${CP_INT_SOPS}" > "${TMP}/cp-intermediate-secret.yaml" \
    || fatal "failed to decrypt ${CP_INT_SOPS} — check ${CP_AGE_KEY} is the right key"

# K8s Secret data fields are base64-encoded YAML scalars; pull tls.crt/tls.key
# out with yq and decode. .venv/bin/yq matches this repo's pinned version
# (same one used by images/docker/talos-cluster-bootstrap).
YQ="${REPO}/.venv/bin/yq"
[ -x "${YQ}" ] || command -v yq >/dev/null || fatal "yq not available (.venv/bin/yq or on PATH)"
YQ="${YQ:-$(command -v yq)}"

"${YQ}" -r '.data["tls.crt"]' "${TMP}/cp-intermediate-secret.yaml" | base64 -d > "${TMP}/cp-intermediate.crt"
"${YQ}" -r '.data["tls.key"]' "${TMP}/cp-intermediate-secret.yaml" | base64 -d > "${TMP}/cp-intermediate.key"
[ -s "${TMP}/cp-intermediate.crt" ] || fatal "decoded controlplane intermediate cert is empty"
[ -s "${TMP}/cp-intermediate.key" ] || fatal "decoded controlplane intermediate key is empty"

# --- Generate observability's intermediate ----------------------------------
# maxPathLen 0: this cluster's intermediate signs leaf SVIDs only, no further
# sub-CAs. controlplane's own intermediate is pathlen:1 specifically to allow
# exactly one more tier (this one) — see generate-controlplane-pki.sh.
cat > "${TMP}/intermediate.tpl" <<'EOF'
{
  "subject": {{ toJson .Subject }},
  "keyUsage": ["certSign", "crlSign"],
  "basicConstraints": {"isCA": true, "maxPathLen": 0}
}
EOF

info "generating observability intermediate (${INT_NOT_AFTER}, maxPathLen=0)"
"${STEP}" certificate create "${INT_CN}" "${TMP}/observability-intermediate.crt" "${TMP}/observability-intermediate.key" \
    --template "${TMP}/intermediate.tpl" --not-after "${INT_NOT_AFTER}" \
    --ca "${TMP}/cp-intermediate.crt" --ca-key "${TMP}/cp-intermediate.key" \
    --no-password --insecure

# --- Verify the full chain before writing anything --------------------------
"${YQ}" -r '.data["root.crt"]' "${CP_ROOT_CERT}" > "${TMP}/root.crt"
[ -s "${TMP}/root.crt" ] || fatal "could not extract root.crt from ${CP_ROOT_CERT}"

cat "${TMP}/cp-intermediate.crt" "${TMP}/root.crt" > "${TMP}/chain-bundle.crt"
openssl verify -CAfile "${TMP}/chain-bundle.crt" -partial_chain "${TMP}/observability-intermediate.crt" >/dev/null \
    || openssl verify -CAfile "${TMP}/chain-bundle.crt" "${TMP}/observability-intermediate.crt" >/dev/null \
    || fatal "observability intermediate does not verify against controlplane-int + root"
openssl x509 -text -noout -in "${TMP}/observability-intermediate.crt" | grep -q 'pathlen:0' \
    || fatal "observability intermediate is missing maxPathLen=0"

INT_NOT_AFTER_DATE="$(openssl x509 -enddate -noout -in "${TMP}/observability-intermediate.crt" | sed 's/notAfter=//')"
info "observability int notAfter: ${INT_NOT_AFTER_DATE}"
info "chain + pathlen verification OK"

# --- Encrypt + write ---------------------------------------------------------
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

# ca.crt = the immediate signing CA's cert (controlplane's intermediate),
# mirroring generate-controlplane-pki.sh's own pattern exactly: that script
# sets ca.crt = root.crt because root is controlplane-int's signer. Here,
# controlplane-int is observability-int's signer, so it goes in ca.crt.
kubectl create secret generic csi-driver-spiffe-ca \
    --namespace=cert-manager \
    --type=kubernetes.io/tls \
    --from-file=tls.crt="${TMP}/observability-intermediate.crt" \
    --from-file=tls.key="${TMP}/observability-intermediate.key" \
    --from-file=ca.crt="${TMP}/cp-intermediate.crt" \
    --dry-run=client -o yaml \
    | kubectl annotate --local -f - -o yaml \
        'ignore-check.kube-linter.io/schema-validation=SOPS-encrypted secret; top-level sops field is expected and non-standard by design' \
    > "${TMP}/intermediate-secret.yaml"
enc "${TMP}/intermediate-secret.yaml" "${INT_OUT}" --data-only
info "wrote ${INT_OUT}"

# Public root cert: identical content to controlplane's own copy (same
# fleet root), no decryption needed — it's public material either way.
cp "${CP_ROOT_CERT}" "${ROOT_CERT_OUT}"
info "wrote ${ROOT_CERT_OUT} (copied from controlplane's, same root)"

# Decrypt round-trip if the private key is available locally.
if [ -f "${CLUSTER_DIR}/.sops.age-key" ]; then
    SOPS_AGE_KEY_FILE="${CLUSTER_DIR}/.sops.age-key" sops -d "${INT_OUT}" > /dev/null \
        && info "decrypt round-trip OK" \
        || fatal "decrypt round-trip FAILED for ${INT_OUT}"
fi

echo ""
info "done. Next steps:"
info "  1. Commit ${INT_OUT#"${REPO}"/} and ${ROOT_CERT_OUT#"${REPO}"/}."
info "  2. Wiring into clusters/observability/kustomization.yaml happens with"
info "     the cert-manager-spiffe-issuer/observability overlay — do not add"
info "     these resources before cert-manager's namespace exists on that cluster."
