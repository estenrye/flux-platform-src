# Runbook: csi-driver-spiffe-ca TrustAnchor Bootstrap

> **Status**: DRAFT - not yet tested. Do not follow in production until this
> runbook has been exercised in a non-production environment and the `[tested]`
> marker added to each step.

## Overview

This runbook provisions the singleton AWS IAM Roles Anywhere TrustAnchor used
by Pattern D. The TrustAnchor is provisioned out-of-band (AWS CLI or
Terraform) because `provider-aws-rolesanywhere` currently exposes `Profile`
but not `TrustAnchor`.

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

## Step 1: Export root CA certificate bundle

Extract the trust anchor certificate from the crossplane cluster:

```bash
kubectl -n cert-manager get secret csi-driver-spiffe-ca \
  -o jsonpath='{.data.tls\.crt}' | base64 --decode > /tmp/csi-driver-spiffe-ca.crt
```

Validate the certificate:

```bash
openssl x509 -in /tmp/csi-driver-spiffe-ca.crt -noout -subject -issuer -dates
```

Expected: certificate details are printed and validity window is correct.

## Step 2: Create TrustAnchor (AWS CLI)

Set your bootstrap variables:

```bash
export AWS_REGION=us-east-2
export TRUST_ANCHOR_NAME=csi-driver-spiffe-ca-root
```

Create request payload:

```bash
cat > /tmp/trust-anchor-create.json <<'EOF'
{
  "name": "REPLACE_TRUST_ANCHOR_NAME",
  "enabled": true,
  "source": {
    "sourceType": "CERTIFICATE_BUNDLE",
    "sourceData": {
      "x509CertificateData": "REPLACE_CERT_PEM"
    }
  }
}
EOF

CERT_ESCAPED=$(awk '{printf "%s\\n", $0}' /tmp/csi-driver-spiffe-ca.crt)
jq \
  --arg name "$TRUST_ANCHOR_NAME" \
  --arg cert "$CERT_ESCAPED" \
  '.name=$name | .source.sourceData.x509CertificateData=$cert' \
  /tmp/trust-anchor-create.json > /tmp/trust-anchor-create.final.json
```

Create the TrustAnchor:

```bash
aws rolesanywhere create-trust-anchor \
  --region "$AWS_REGION" \
  --cli-input-json file:///tmp/trust-anchor-create.final.json \
  > /tmp/trust-anchor-create.out.json
```

Capture outputs:

```bash
export TRUST_ANCHOR_ARN=$(jq -r '.trustAnchor.trustAnchorArn' /tmp/trust-anchor-create.out.json)
export TRUST_ANCHOR_ID=$(jq -r '.trustAnchor.trustAnchorId' /tmp/trust-anchor-create.out.json)
echo "$TRUST_ANCHOR_ID"
echo "$TRUST_ANCHOR_ARN"
```

## Step 2b: Create TrustAnchor (Terraform alternative)

Use this path instead of Step 2 if your platform bootstrap is Terraform-first.

Create a minimal Terraform module:

```hcl
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type = string
}

variable "trust_anchor_name" {
  type = string
}

variable "certificate_bundle_pem" {
  type = string
}

resource "aws_rolesanywhere_trust_anchor" "this" {
  name    = var.trust_anchor_name
  enabled = true

  source {
    source_type = "CERTIFICATE_BUNDLE"
    source_data {
      x509_certificate_data = var.certificate_bundle_pem
    }
  }
}

output "trust_anchor_arn" {
  value = aws_rolesanywhere_trust_anchor.this.arn
}

output "trust_anchor_id" {
  value = aws_rolesanywhere_trust_anchor.this.id
}
```

Create variables from the exported certificate:

```bash
cat > terraform.tfvars <<'EOF'
aws_region = "us-east-2"
trust_anchor_name = "csi-driver-spiffe-ca-root"
certificate_bundle_pem = <<EOT
REPLACE_CERT_PEM
EOT
EOF

CERT_CONTENT=$(cat /tmp/csi-driver-spiffe-ca.crt)
awk -v cert="$CERT_CONTENT" '{gsub("REPLACE_CERT_PEM", cert)}1' terraform.tfvars > terraform.tfvars.final
mv terraform.tfvars.final terraform.tfvars
```

Apply and capture outputs:

```bash
terraform init
terraform apply
export TRUST_ANCHOR_ARN=$(terraform output -raw trust_anchor_arn)
export TRUST_ANCHOR_ID=$(terraform output -raw trust_anchor_id)
echo "$TRUST_ANCHOR_ID"
echo "$TRUST_ANCHOR_ARN"
```

Expected: Terraform creates exactly one `aws_rolesanywhere_trust_anchor` and
returns both ARN and ID.

## Step 3: Verify TrustAnchor state

```bash
aws rolesanywhere get-trust-anchor \
  --region "$AWS_REGION" \
  --trust-anchor-id "$TRUST_ANCHOR_ID" \
  | jq '{id: .trustAnchor.trustAnchorId, arn: .trustAnchor.trustAnchorArn, enabled: .trustAnchor.enabled, sourceType: .trustAnchor.source.sourceType}'
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
- [csi-driver-spiffe-ca Scheduled Rotation](./csi-driver-spiffe-ca-scheduled-rotation.md)
- [csi-driver-spiffe-ca Emergency Key Compromise Rollover](./csi-driver-spiffe-ca-emergency-rollover.md)