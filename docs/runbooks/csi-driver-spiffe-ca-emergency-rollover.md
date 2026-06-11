# Runbook: csi-driver-spiffe-ca Emergency Key Compromise Rollover

> **Status**: DRAFT — not yet tested. Do not follow in production until this
> runbook has been exercised in a non-production environment and the `[tested]`
> marker added to each step.

## Overview

This runbook covers an emergency rotation of the `csi-driver-spiffe-ca` root
CA following a suspected or confirmed private key compromise. This is a
break-glass procedure that should be treated as a P1 incident.

**Impact**: Until the rotation is complete, all workload cluster intermediate
CAs and SVIDs are potentially compromised. AWS sessions obtained via
compromised SVIDs should be considered hostile.

**Coordinate with**: Security team, AWS account owner, workload cluster
operators.

## Immediate triage checklist

Before executing this runbook, answer:

- [ ] Is the compromise confirmed or suspected? (Scope response accordingly.)
- [ ] Which clusters have active Roles Anywhere sessions using SVIDs from this
  trust anchor? (`aws rolesanywhere list-subjects` or CloudTrail `CreateSession`
  events.)
- [ ] Are there active AWS API calls from compromised credentials that must be
  revoked immediately? (Consider disabling the IAM Role or Roles Anywhere
  Profile as a faster first step — see Step 0 below.)

## Step 0: Authenticate to the AWS CLI

```bash
make auth-aws
```

## Step 1: List All AWS Roles Anywhere Profiles or TrustAnchors

To get the list of AWS Roles Anywhere Profiles that trust the compromised CA, run:

```bash
make aws-list-rolesanywhere-profiles
```

To get the list of AWS Roles Anywhere TrustAnchors, run:

```bash
make aws-list-rolesanywhere-trust-anchors
```

## Step 2: Emergency traffic cutoff (if active exploitation is confirmed)

If you have confirmed active exploitation, disable the Roles Anywhere profile
before rotating the CA. This stops new sessions immediately without waiting for
the full rotation.

```bash
make aws-disable-rolesanywhere-profile PROFILE_ID=<profileId>
```

Or disable the entire TrustAnchor (affects all clusters):

```bash
make aws-disable-rolesanywhere-trust-anchor TRUST_ANCHOR_ID=<trustAnchorId>
```

> Re-enable after rotation and validation (Step 9).

## Step 3: Revoke compromised CA in step-ca CRL

List issued intermediate CA certificates:

```
step ca certificate-list --ca-url https://<step-ca-address> --admin-provisioner admin
```

For each workload cluster intermediate CA signed by the compromised root:

```
step ca revoke <serial-number> \
  --ca-url https://<step-ca-address> \
  --reason keyCompromise \
  --admin-provisioner admin
```

Verify CRL is updated:

```
step crl inspect --from $(step ca crl --ca-url https://<step-ca-address>)
```

IAM Roles Anywhere will honor the CRL on the next `CreateSession` call once
the cached CRL TTL expires. Pair with Step 2 for immediate cutoff.

## Step 4: Generate new root CA

Force cert-manager to issue a new `csi-driver-spiffe-ca` with a new keypair by
deleting the existing secret (cert-manager recreates it immediately):

```
kubectl delete secret csi-driver-spiffe-ca -n cert-manager
```

cert-manager will issue a new certificate from the `selfsigned` ClusterIssuer
within seconds.

Verify:

```
kubectl get certificate csi-driver-spiffe-ca -n cert-manager -o wide
kubectl get secret csi-driver-spiffe-ca -n cert-manager -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -subject -dates
```

Expected: new `Not After` date and a new public key fingerprint compared to the
compromised cert.

## Step 5: Update TrustAnchor with new cert only

> In a normal rotation, both old and new certs overlap in the bundle. In a
> compromise scenario, the old cert must be **removed immediately** — do not
> add an overlap window.

Update the TrustAnchor `CERTIFICATE_BUNDLE` to contain only the new root cert:

```
NEW_CERT=$(kubectl get secret csi-driver-spiffe-ca -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d)

aws rolesanywhere update-trust-anchor \
  --trust-anchor-id <trustAnchorId> \
  --source '{"sourceType":"CERTIFICATE_BUNDLE","sourceData":{"x509CertificateData":"'"$(echo "$NEW_CERT" | base64)"'"}}' \
  --region us-east-2
```

Or update via Crossplane by patching the managed resource spec.

Verify:

```
aws rolesanywhere get-trust-anchor --trust-anchor-id <trustAnchorId> --region us-east-2
```

## Step 6: Restart step-ca with new root

```
kubectl rollout restart deployment/step-ca -n step-ca
kubectl rollout status deployment/step-ca -n step-ca
```

Verify step-ca is using the new root:

```
step ca root --ca-url https://<step-ca-address> | \
  openssl x509 -noout -fingerprint -sha256
```

Compare fingerprint to:

```
kubectl get secret csi-driver-spiffe-ca -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -fingerprint -sha256
```

They must match.

## Step 7: Re-issue all workload cluster intermediate CAs

For each workload cluster, force renewal of the intermediate CA:

```
kubectl delete secret csi-driver-spiffe-ca -n cert-manager   # on workload cluster
```

cert-manager will immediately request a new intermediate CA from step-ca (via
step-issuer). The new intermediate CA will be signed by the new root.

Verify chain:

```
kubectl get secret csi-driver-spiffe-ca -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer
```

The issuer CN must match the new root CA's subject.

## Step 8: Re-issue all SVIDs

spiffe-csi-driver detects the new issuer cert and re-issues all mounted SVIDs
automatically. Monitor for issuing errors:

```
kubectl get events -n spiffe-csi --field-selector reason=FailedIssuing
```

For any stuck SVIDs, restart the pod to force re-mount:

```
kubectl delete pod <pod-name> -n <namespace>
```

## Step 9: Re-enable Roles Anywhere profile (if disabled in Step 2)

After verifying all workload clusters have valid SVIDs chaining to the new root:

```bash
make aws-enable-rolesanywhere-profile PROFILE_ID=<profileId>
```


Verify by attempting a `CreateSession` with a freshly issued SVID:

```
aws_signing_helper credential-process \
  --certificate /path/to/svid.crt \
  --private-key /path/to/svid.key \
  --trust-anchor-arn arn:aws:rolesanywhere:us-east-2:832767337984:trust-anchor/<trustAnchorId> \
  --profile-arn arn:aws:rolesanywhere:us-east-2:832767337984:profile/<profileId> \
  --role-arn arn:aws:iam::832767337984:role/<roleName>
```

## Step 8: Post-incident actions

- [ ] Generate an incident report. Record the timeline, blast radius, and
  resolution.
- [ ] Audit CloudTrail for all `CreateSession` events during the compromise
  window. Assess data exposure.
- [ ] Rotate any long-lived credentials or secrets that were accessible via
  the compromised IAM role during the window.
- [ ] Review and tighten IAM permission policy scope if needed.
- [ ] Update this runbook with lessons learned.
- [ ] File a task to improve detection (alert on anomalous `CreateSession`
  volume or unusual source IP for Roles Anywhere sessions).

## Related

- [Scheduled Rotation Runbook](./csi-driver-spiffe-ca-scheduled-rotation.md)
- [ADR 0007 Phase 1](../adr/0007-crossplane-composition-for-externaldns-and-certmanager-iam-roles-anywhere.md#phase-1-certificate-duration-decision)
