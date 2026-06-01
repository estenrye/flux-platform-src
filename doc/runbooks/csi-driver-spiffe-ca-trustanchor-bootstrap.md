# Runbook: csi-driver-spiffe-ca TrustAnchor Bootstrap

> **Status**: DRAFT - not yet tested. Do not follow in production until this
> runbook has been exercised in a non-production environment and the `[tested]`
> marker added to each step.

## Overview

This runbook provisions the singleton AWS IAM Roles Anywhere TrustAnchor used
by Pattern D. The TrustAnchor is provisioned out-of-band (AWS CLI or
Terraform) because `provider-aws-rolesanywhere` currently exposes `Profile`
but not `TrustAnchor`.

For the CloudFormation-based bootstrap flow that this runbook should stay in
sync with, see [ADR 0005](../adr/0005-using-cert-manager-to-issue-spiffe-x-509-svid-certificates-for-iam-access-roles-anywhere.md).

Upstream tracking:

- [crossplane-contrib/provider-upjet-aws#2092](https://github.com/crossplane-contrib/provider-upjet-aws/issues/2092)

Output of this runbook:

- One AWS IAM Roles Anywhere TrustAnchor created from the crossplane cluster
  root CA certificate (`csi-driver-spiffe-ca`).
- The TrustAnchor ARN published to platform configuration for
  `XDelegatedHostedZoneAWS.spec.trustAnchorArn`.

## Prerequisites

- `kubectl` access to the crossplane cluster.
- AWS permissions for Roles Anywhere TrustAnchor operations:
  `rolesanywhere:CreateTrustAnchor`, `rolesanywhere:GetTrustAnchor`,
  `rolesanywhere:EnableCrl`, and `rolesanywhere:ListTrustAnchors`.
- `aws` CLI v2 configured for the target account and region.
- `jq` installed.

## Step 0: Confirm provider capability (no TrustAnchor managed resource)

```bash
kubectl api-resources | grep rolesanywhere
```

Expected: `Profile` resources are listed, and no `TrustAnchor` resource is
listed.

## Step 1: Deploy the TrustAnchor using the AWS CLI and CloudFormation

```bash
make aws-deploy-cloudformation-stack-rolesanywhere
```

## Step 2: Extract the TrustAnchor ARN and ID from CloudFormation outputs

```bash
TRUST_ANCHOR_ARN=`make aws-get-cloudformation-stack-outputs-trust-anchor-arn`
TRUST_ANCHOR_ID=`make aws-get-cloudformation-stack-outputs-trust-anchor-id`
echo "TrustAnchor ARN: $TRUST_ANCHOR_ARN"
echo "TrustAnchor ID: $TRUST_ANCHOR_ID"
```

## Step 3: Verify TrustAnchor state

```bash
make aws-list-rolesanywhere-trust-anchors
```

Expected:

- `enabled` is `true`.
- `sourceType` is `CERTIFICATE_BUNDLE`.
- ARN matches `TRUST_ANCHOR_ARN`.

## Step 4: Enable CRL checking (if using CRL revocation)

If you are using CDP or imported CRLs for intermediate CA revocation, enable
CRL support on the TrustAnchor.

```bash
aws rolesanywhere enable-crl \
  --region "$AWS_REGION" \
  --trust-anchor-id "$TRUST_ANCHOR_ID"
```

Verify:

```bash
aws rolesanywhere get-trust-anchor \
  --region "$AWS_REGION" \
  --trust-anchor-id "$TRUST_ANCHOR_ID" \
  | jq '{id: .trustAnchor.trustAnchorId, hasCrl: (.trustAnchor | has("notificationSettings"))}'
```

## Step 5: Publish TrustAnchor ARN to platform configuration

Publish the ARN into the platform configuration source consumed by
`XDelegatedHostedZoneAWS` claims.

Recommended target: a singleton Crossplane `EnvironmentConfig` that contains
`trustAnchorArn`.

Example:

```yaml
apiVersion: apiextensions.crossplane.io/v1beta1
kind: EnvironmentConfig
metadata:
  name: platform-iam-rolesanywhere
data:
  trustAnchorArn: arn:aws:rolesanywhere:us-east-2:123456789012:trust-anchor/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

Apply and verify:

```bash
kubectl apply -f /path/to/platform-iam-rolesanywhere.environmentconfig.yaml
kubectl get environmentconfig platform-iam-rolesanywhere -o yaml | grep trustAnchorArn
```

## Step 6: Smoke test with one claim

Create or reconcile one `XDelegatedHostedZoneAWS` claim with:

- `spec.trustAnchorArn` set from platform config.
- valid `spec.iamProviderConfigRef` and `spec.rolesAnywhereProviderConfigRef`.

Verify:

```bash
kubectl get xdelegatedhostedzoneaws <name> -o jsonpath='{.status.trustAnchorArn}'
kubectl get xdelegatedhostedzoneaws <name> -o jsonpath='{.status.profileArn}'
kubectl get xdelegatedhostedzoneaws <name> -o jsonpath='{.status.iamRoleArn}'
```

Expected: all ARNs resolve and claim is `Ready=True`.

## Rollback

If bootstrap was created with incorrect certificate material or wrong account:

1. Disable affected Roles Anywhere Profiles to stop new sessions.
2. Delete and recreate the TrustAnchor with the correct certificate bundle.
3. Republish the corrected ARN to platform config.
4. Reconcile one canary claim before broad rollout.

## Related

- [ADR 0007 Phase 2](../adr/0007-crossplane-composition-for-externaldns-and-certmanager-iam-roles-anywhere.md#phase-2-single-trust-anchor-bootstrap-and-step-ca-deployment)
- [ADR 0005 CloudFormation bootstrap procedure](../adr/0005-using-cert-manager-to-issue-spiffe-x-509-svid-certificates-for-iam-access-roles-anywhere.md#configuring-aws-iam-access-roles-anywhere-to-trust-cert-manager-issued-spiffe-certificates)
- [csi-driver-spiffe-ca Scheduled Rotation](./csi-driver-spiffe-ca-scheduled-rotation.md)
- [csi-driver-spiffe-ca Emergency Key Compromise Rollover](./csi-driver-spiffe-ca-emergency-rollover.md)