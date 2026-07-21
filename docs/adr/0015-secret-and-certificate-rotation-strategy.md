# 15. Secret and Certificate Rotation Strategy

Date: 2026-06-10

## Status

Accepted

## Context

The platform manages several categories of secrets and certificates with
different owners, rotation mechanisms, and failure modes:

- **SPIFFE CA certificates** — issued by cert-manager, used as the root of
  trust for IAM Roles Anywhere
- **SOPS age keys** — asymmetric keypairs used to encrypt secrets committed to
  the repository
- **External Secrets** — runtime secrets fetched from 1Password by External
  Secrets Operator
- **Deploy keys** — SSH keys used by Flux to pull from rendered repositories
- **GitHub App credentials** — used by CI to push to rendered repositories

Each category has a different rotation mechanism. Treating them the same leads
to either under-rotation (security risk) or over-rotation (operational burden
without proportional security benefit).

## Decision

We define rotation cadence and mechanism per secret category:

### SPIFFE CA certificates (`csi-driver-spiffe-ca`)

- **Rotation cadence**: 90 days (automated by cert-manager)
- **Mechanism**: cert-manager renews the certificate ~30 days before expiry.
  The rotation cascade (TrustAnchor bundle update → step-ca restart →
  intermediate CA re-issue → SVID re-issue) must complete within the renewal
  window.
- **Key rotation**: `privateKey.rotationPolicy: Always` — the private key
  rotates on every renewal once Phase 2 TrustAnchor bundle overlap automation
  is in place (see ADR-7 Phase 1).
- **Runbooks**:
  - Scheduled rotation: `docs/runbooks/csi-driver-spiffe-ca-scheduled-rotation.md`
  - Emergency rollover: `docs/runbooks/csi-driver-spiffe-ca-emergency-rollover.md`
  - Trust anchor bootstrap: `docs/runbooks/csi-driver-spiffe-ca-trustanchor-bootstrap.md`

### SOPS age keys

- **Rotation cadence**: On-demand (when key compromise is suspected, or annually
  as a hygiene measure)
- **Mechanism**: Manual.
  1. Generate a new age keypair: `age-keygen -o new-key.txt`
  2. Re-encrypt all SOPS-encrypted files in the repository using both the old
     and new public keys (so the new key can decrypt, while in-flight CI runs
     using the old key still succeed):
     ```bash
     find . -name "*.sops.yaml" -exec sops updatekeys {} \;
     ```
  3. Update `.sops.yaml` to list only the new public key.
  4. Update the `sops-age` Kubernetes secret on all clusters:
     ```bash
     kubectl create secret generic sops-age \
       --namespace=flux-system \
       --from-file=age.agekey=new-key.txt \
       --dry-run=client -o yaml | kubectl apply -f -
     ```
  5. Remove the old public key from `.sops.yaml` and re-encrypt all files
     using only the new key.
- **Failure mode**: If the age secret is lost and the old key is unavailable,
  SOPS-encrypted secrets in the rendered repository cannot be decrypted and
  Flux reconciliation will fail for any component using those secrets.

### External Secrets (1Password via External Secrets Operator)

- **Rotation cadence**: No action required. ESO re-fetches secrets from
  1Password on every reconciliation cycle (default: every 1 hour).
- **Mechanism**: Update the secret value in 1Password. ESO will pick up the
  new value on the next sync. No Kubernetes secret needs to be manually updated.
- **Exception**: The `OP_SERVICE_ACCOUNT_TOKEN` GitHub secret (used by CI) must
  be rotated in both 1Password and the GitHub repository secrets when a new
  service account token is issued.

### Flux deploy keys (SSH)

- **Rotation cadence**: On-demand (when key compromise is suspected, or when
  access needs to be revoked)
- **Mechanism**:
  1. Generate a new SSH keypair: `ssh-keygen -t ed25519 -f new-deploy-key`
  2. Add the new public key to the rendered repository's deploy keys via `gh`:
     ```bash
     gh repo deploy-key add new-deploy-key.pub \
       --repo <owner>/<rendered-repo> \
       --title "flux-$(date +%Y%m%d)"
     ```
  3. Update the Flux `GitRepository` secret on the cluster with the new private key.
  4. Remove the old deploy key from the rendered repository.

### GitHub App credentials (render-flux-platform-src-app)

- **Rotation cadence**: Annually, or immediately on suspected compromise
- **Mechanism**: Rotate the private key in the GitHub App settings and update
  the `private-key` item in the `flux-platform-src` 1Password vault. The new
  key is picked up by CI on the next run via the `load-secrets-action`.

## Consequences

- SOPS age key rotation is the most operationally complex rotation in this list.
  Key loss without a backup is unrecoverable — the repository would need to be
  re-encrypted from scratch using plaintext values sourced from 1Password.
  Back up age private keys in a secure location (e.g., the 1Password vault)
  separately from the repository.
- Automated SPIFFE CA rotation requires the TrustAnchor bundle overlap controller
  described in ADR-7 Phase 1 to be in place before enabling
  `privateKey.rotationPolicy: Always`. Enabling key rotation without the
  overlap controller causes an immediate IAM Roles Anywhere outage.
- External Secrets rotation is transparent to operators — the only action is
  updating the value in 1Password.

## References

- [ADR-5: Using cert-manager to issue SPIFFE X.509 SVID Certificates](0005-using-cert-manager-to-issue-spiffe-x-509-svid-certificates-for-iam-access-roles-anywhere.md)
- [ADR-7: Crossplane Composition for ExternalDNS and CertManager IAM Roles Anywhere](0007-crossplane-composition-for-externaldns-and-certmanager-iam-roles-anywhere.md)
- [Runbook: Scheduled SPIFFE CA rotation](../runbooks/csi-driver-spiffe-ca-scheduled-rotation.md)
- [Runbook: Emergency SPIFFE CA rollover](../runbooks/csi-driver-spiffe-ca-emergency-rollover.md)
- [Runbook: Trust anchor bootstrap](../runbooks/csi-driver-spiffe-ca-trustanchor-bootstrap.md)
- [Mozilla SOPS](https://github.com/getsops/sops)
- [age encryption](https://github.com/FiloSottile/age)

## Amendment 2026-07-21 (fresh offline root on `controlplane`, M2)

The SPIFFE CA certificates section above described the deployed reality
on Rackspace Spot, which the M0 audit found was not what ADR-5 intended:
there was no step-ca-owned root at all. The fleet trust anchor was
`csi-driver-spiffe-ca`, a cert-manager self-signed Certificate
auto-rotating every 90 days; ESO copied it to step-ca's namespace and
step-ca merely mounted and served it. That 90-day churn would have
forced every AWS Roles Anywhere trust anchor — and, from M4 on, every
workload cluster's chained intermediate — to re-anchor quarterly.

[ADR-24](0024-m2-control-plane-service-migration-off-spot.md) (M2)
replaces this on `controlplane` with a **stable offline root**
(`ryezone-labs Root CA`, 10 years, ECDSA P-256, SOPS-encrypted, private
key never applied to any cluster) and a **1-year `controlplane`
intermediate** (`maxPathLen=1`). The `csi-driver-spiffe-ca` Secret name
and the ESO cert-manager→step-ca sync pattern are unchanged — only the
key material and its provenance changed, so chart mounts and
`ClusterIssuer` wiring didn't need to move.

Revised rotation cadence for `controlplane`:

- **Root**: no automated rotation. Rotates only by deliberate ceremony
  (`.bin/generate-controlplane-pki.sh`, run by a human so the root key
  never touches an agent session).
- **Intermediate**: annual, or by drill (plan M11 quarterly rotation
  drills apply to the intermediate, not the root).
- The pinned-fingerprint-goes-stale failure mode from the 90-day-rotating
  root is gone — the fingerprint recorded in `values/controlplane.env`
  and this repo's memory is now stable for the root's 10-year lifetime.

This amendment applies to `controlplane` only. `docs/runbooks/
csi-driver-spiffe-ca-scheduled-rotation.md` and the emergency-rollover
runbook still apply verbatim to the *intermediate*; they were written
against the old 90-day cert-manager-rotated model and should be reread
with "the rotating certificate" now meaning the intermediate, not a
self-signed root.
