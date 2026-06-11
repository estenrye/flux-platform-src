# Runbook: csi-driver-spiffe-ca Scheduled Rotation

> **Status**: DRAFT — not yet tested. Do not follow in production until this
> runbook has been exercised in a non-production environment and the `[tested]`
> marker added to each step.

## Overview

cert-manager automatically renews `csi-driver-spiffe-ca` approximately 30 days
before expiry (at ~day 60 of the 90-day certificate). When `rotationPolicy:
Always` is enabled (gated on Phase 2 automation — see
[ADR 0007](../adr/0007-crossplane-composition-for-externaldns-and-certmanager-iam-roles-anywhere.md#phase-1-certificate-duration-decision)),
each renewal generates a new keypair and triggers the full cascade described
below.

Until `rotationPolicy: Always` is enabled, cert-manager renews only the
certificate validity window and reuses the existing private key. In that mode
this runbook does not apply.

## Prerequisites

- `kubectl` access to the crossplane cluster.
- IAM permissions to update a Roles Anywhere TrustAnchor (or Crossplane
  manages this automatically — see Phase 2).
- `step` CLI installed for CRL and revocation verification.

## Automated rotation sequence

When `rotationPolicy: Always` is active and Phase 2 automation is deployed,
the following steps execute without operator intervention. This runbook
documents them for observability and troubleshooting.

### Step 1: cert-manager renews the root CA (automated)

cert-manager renews `csi-driver-spiffe-ca` ~30 days before expiry.

```
kubectl get certificate csi-driver-spiffe-ca -n cert-manager -o wide
```

Expected: `READY=True`, `RENEWAL TIME` updated, `NOT AFTER` extended by 90
days. The `cert-manager` Secret `csi-driver-spiffe-ca` now contains the new
keypair.

### Step 2: TrustAnchor bundle updated (automated by Phase 2 controller)

The TrustAnchor overlap controller detects the secret change and appends the
new root cert to the `CERTIFICATE_BUNDLE` while retaining the old cert.

Verify both certs are present in the bundle:

```
kubectl get trustanchor csi-driver-spiffe-ca -o jsonpath='{.status.atProvider.certificateBundle}' \
  | base64 -d | openssl storeutl -noout -text /dev/stdin 2>/dev/null | grep "Not After"
```

Expected: two certificates with different `Not After` timestamps.

### Step 3: step-ca restarted with new root (automated)

step-ca pod is restarted (rolling restart) after the secret changes.

```
kubectl rollout status deployment/step-ca -n step-ca
```

Verify step-ca is issuing from the new root:

```
step ca health
step ca root --ca-url https://<step-ca-address> | \
  openssl x509 -noout -subject -issuer -dates
```

### Step 4: Workload cluster intermediate CAs re-issued (automated)

Each workload cluster's step-issuer detects that its `StepClusterIssuer` CA
cert no longer matches the current root and triggers a `CertificateRequest` to
step-ca. The new intermediate CA is signed by the new root.

For each workload cluster:

```
kubectl get certificate csi-driver-spiffe-ca -n cert-manager -o wide
kubectl get certificaterequest -n cert-manager --sort-by=.metadata.creationTimestamp | tail -5
```

Expected: a fresh `CertificateRequest` approved and issued, new intermediate CA
cert in the secret.

### Step 5: SVIDs re-issued (automated by spiffe-csi-driver)

spiffe-csi-driver detects the new issuer and triggers re-issuance of all
mounted SVIDs. Pods do not restart; the CSI volume is updated in place.

Verify SVIDs are chaining to the new root:

```
# On a workload cluster node with an SVID-mounted pod:
openssl verify -CAfile <(kubectl get secret csi-driver-spiffe-ca -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d) \
  <path-to-svid-cert>
```

### Step 6: Old root cert removed from TrustAnchor bundle (automated)

After all workload clusters report healthy (all SVIDs chaining to new root),
the overlap controller removes the old root cert from the bundle.

Verify only one cert remains:

```
kubectl get trustanchor csi-driver-spiffe-ca -o jsonpath='{.status.atProvider.certificateBundle}' \
  | base64 -d | openssl storeutl -noout -text /dev/stdin 2>/dev/null | grep -c "Certificate"
```

Expected: `1`.

## Rollback

> This section must be expanded with a tested procedure before `rotationPolicy:
> Always` is enabled in production.

If the rotation cascade stalls (e.g., a workload cluster is unreachable):

1. Do **not** remove the old root cert from the TrustAnchor bundle until all
   workload clusters have re-issued their intermediate CAs. The overlap window
   keeps both generations valid.
2. If step-ca fails to start with the new root:
   - Revert the `csi-driver-spiffe-ca` secret to the previous keypair from
     backup (see emergency rollover runbook).
   - The bundle overlap means existing sessions remain valid during recovery.
3. If automation is unavailable, follow the manual steps in this runbook using
   the `step` CLI and `kubectl`.

## Observability

Key metrics and alerts to configure before enabling `rotationPolicy: Always`:

- Alert: `csi-driver-spiffe-ca` certificate `READY=False` for >5 minutes.
- Alert: TrustAnchor bundle contains >2 certs (overlap window exceeded 24h).
- Alert: Workload cluster intermediate CA age > 91 days (re-issuance stalled).
- Alert: SVID issuing failures on spiffe-csi-driver (certificate request errors).

## Related

- [Emergency Rollover Runbook](./csi-driver-spiffe-ca-emergency-rollover.md)
- [ADR 0007 Phase 1](../adr/0007-crossplane-composition-for-externaldns-and-certmanager-iam-roles-anywhere.md#phase-1-certificate-duration-decision)
