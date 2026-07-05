---
name: step-ca-connectivity-validation
description: How to validate step-ca is reachable and serving the correct root CA certificate
metadata:
  type: reference
---

# step-ca Connectivity Validation

Health endpoint: `https://ca.crossplane.rye.ninja/health`

Use `-k` because step-ca serves a self-signed certificate.

```bash
curl -sk https://ca.crossplane.rye.ninja/health
# expected: {"status":"ok"}
```

Root CA fingerprint is in the `csi-driver-spiffe-ca` secret in the `step-ca` namespace (`tls.crt` key):

```bash
export KUBECONFIG=~/.kube/spot/ryezone-labs/crossplane-controlplane-cluster.yaml

FINGERPRINT=$(kubectl get secret csi-driver-spiffe-ca -n step-ca \
  -o jsonpath='{.data.tls\.crt}' \
  | base64 -d \
  | openssl x509 -noout -fingerprint -sha256 \
  | sed 's/.*=//;s/://g' \
  | tr '[:upper:]' '[:lower:]')

curl -sk "https://ca.crossplane.rye.ninja/root/${FINGERPRINT}" | python3 -m json.tool
# expected: {"ca": "-----BEGIN CERTIFICATE-----\n..."}
```

## Bootstrap step CLI

To configure the local `step` CLI to target this CA:

```bash
step ca bootstrap \
  --ca-url https://ca.crossplane.rye.ninja \
  --fingerprint $FINGERPRINT
```

Writes CA config and root cert to `~/.step`. Subsequent `step` commands use this CA by default.

See also: [[cluster-kubeconfig-lookup]] for kubeconfig path.
Full validation procedure documented in [ADR 0005](../adr/0005-using-cert-manager-to-issue-spiffe-x-509-svid-certificates-for-iam-access-roles-anywhere.md).
