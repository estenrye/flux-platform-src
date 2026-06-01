# Evidence Log: csi-driver-spiffe-ca TrustAnchor Bootstrap

Use this template to record execution evidence for ADR 0007 Phase 2 acceptance
criteria after running
[csi-driver-spiffe-ca-trustanchor-bootstrap.md](./csi-driver-spiffe-ca-trustanchor-bootstrap.md).

## Test metadata

- Date (UTC):
- Operator:
- Environment:
- AWS account:
- AWS region:
- Git commit:

## Criterion 1: TrustAnchor existence and ARN retrieval via AWS API

Commands:

```bash
make aws-get-cloudformation-stack-outputs-trust-anchor-arn
make aws-get-cloudformation-stack-outputs-trust-anchor-id
aws rolesanywhere get-trust-anchor --region "$AWS_REGION" --trust-anchor-id "$TRUST_ANCHOR_ID"
```

Observed output summary:

- TRUST_ANCHOR_ARN:
- TRUST_ANCHOR_ID:
- AWS get-trust-anchor ARN/ID match: yes|no

Pass: yes|no

## Criterion 2: Claims consume shared trustAnchorArn automatically

Commands:

```bash
kubectl get environmentconfig platform-iam-rolesanywhere -o yaml | grep trustAnchorArn
kubectl get xdelegatedhostedzoneaws -n crossplane-controlplane-cluster crossplane-rye-ninja -o jsonpath='{.spec.trustAnchorArn}'
kubectl get xdelegatedhostedzoneaws -n crossplane-controlplane-cluster crossplane-rye-ninja -o jsonpath='{.status.trustAnchorArn}'
```

Observed output summary:

- Platform config trustAnchorArn:
- Claim spec.trustAnchorArn (expected empty for defaulting test):
- Claim status.trustAnchorArn:
- Status matches platform config: yes|no

Pass: yes|no

## Criterion 3: CRL endpoint reachable and revocation enforced

Commands:

```bash
# Example placeholders - replace with environment-specific commands.
step ca revoke <serial>
kubectl get events -n crossplane-controlplane-cluster --sort-by=.lastTimestamp \
  | grep -Ei 'rolesanywhere|CreateSession|revoke|revoked' | tail -n 40
```

Observed output summary:

- Revoked certificate serial:
- CRL update observed at:
- CreateSession failure observed after revocation: yes|no
- Evidence source (event/log link or command transcript):

Pass: yes|no

## Additional notes

-

## Final decision

- Phase 2 criteria validated: yes|no
- Follow-up actions:
