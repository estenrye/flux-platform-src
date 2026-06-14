# Design: step-ca SPIFFE Capability Chainsaw Tests

Date: 2026-06-14

## Overview

Kyverno Chainsaw integration tests that validate the step-ca capabilities required to support the SPIFFE implementation described in ADR-0005 and ADR-0007. Two independent test suites — external (runs on the test runner against `ca.crossplane.rye.ninja`) and internal (runs inside the cluster via a Kubernetes Job) — each validate the same five capabilities.

## Capabilities Under Test

| Capability | Why it matters |
|---|---|
| Health endpoint | step-ca is running and serving |
| Root CA fingerprint API | Correct root CA is loaded and reachable |
| X5C provisioner — issue intermediate CA cert | ADR-0007 Pattern D bootstrap: workload clusters receive an intermediate CA signed by the crossplane root via X5C |
| Certificate revocation | Revocation via `step ca revoke` regenerates the CRL |
| CRL contains revoked serial | CRL endpoint reflects revocations; required for PKI hygiene |

## Directory Structure

```
tests/
└── step-ca/
    ├── external/
    │   ├── chainsaw-test.yaml
    │   └── resources/
    │       └── certificate.yaml
    └── internal/
        ├── chainsaw-test.yaml
        └── resources/
            ├── certificate.yaml
            └── test-job.yaml
```

## Shared: cert-manager Certificate

Both test suites create a `Certificate` in their chainsaw-managed namespace using the `csi-driver-spiffe-issuer` ClusterIssuer. This issues a leaf cert signed by `csi-driver-spiffe-ca` — the trusted root configured in step-ca's X5C provisioner.

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: step-ca-x5c-test-cert
spec:
  secretName: step-ca-x5c-test-cert
  duration: 1h
  commonName: step-ca-x5c-test
  issuerRef:
    name: csi-driver-spiffe-issuer
    kind: ClusterIssuer
  usages:
    - digital signature
```

The resulting Secret (`step-ca-x5c-test-cert`) provides `tls.crt` and `tls.key`, used as the X5C authentication token in the provisioner step.

## External Test Suite

**File:** `tests/step-ca/external/chainsaw-test.yaml`

Runs on the test runner (local machine). Requires `curl`, `kubectl`, `step`, and `openssl` on PATH. Uses `.venv/bin/step` from the project. All requests target `https://ca.crossplane.rye.ninja` with `-k` (self-signed TLS).

### Steps

| Step | Description |
|---|---|
| `create-test-cert` | Apply `resources/certificate.yaml` |
| `wait-for-cert` | Assert `Certificate` condition `Ready=True` |
| `health` | `curl -sk .../health` → assert body is `{"status":"ok"}` |
| `root-ca` | Read fingerprint from `csi-driver-spiffe-ca` Secret in `step-ca` namespace; `curl -sk .../root/<fingerprint>` → assert `ca` key present in response |
| `x5c-provisioner` | Extract cert/key from test Secret to tmp files; `step ca certificate --provisioner x5c --x5c-cert --x5c-key`; assert issued cert contains `CA:TRUE` via `openssl x509 -text` |
| `revoke` | `step ca revoke --cert <issued.crt> --key <issued.key>` |
| `crl-contains-revoked` | `curl -sk .../1.0/crl` → convert DER to PEM via `openssl crl -inform DER`; extract serial from issued cert via `openssl x509 -serial -noout`; assert serial appears in CRL output |

### CA URL
`https://ca.crossplane.rye.ninja`

### Root fingerprint source
Derived at runtime from the `csi-driver-spiffe-ca` Secret in the `step-ca` namespace, same method as documented in `docs/memory/step-ca-connectivity-validation.md`.

## Internal Test Suite

**File:** `tests/step-ca/internal/chainsaw-test.yaml`

Deploys a Kubernetes `Job` into the chainsaw-managed namespace. The Job runs the `smallstep/step-cli` image and performs all checks against the in-cluster URL. Chainsaw asserts `Job.status.succeeded == 1`.

### CA URL
`https://step-certificates.step-ca.svc.cluster.local:9000`

### Volumes mounted into the Job

| Volume | Source | Mount path | Purpose |
|---|---|---|---|
| `x5c-test-cert` | `step-ca-x5c-test-cert` Secret (test namespace) | `/x5c-cert` | X5C auth cert and key |
| `root-ca` | `csi-driver-spiffe-ca` Secret (`step-ca` namespace) | `/root-ca` | Root CA cert for TLS validation and fingerprint derivation |

The root CA cert is copied into the test namespace via a chainsaw `script` step before the Job is deployed (see Cross-Namespace Secret Access below).

### Steps

| Step | Description |
|---|---|
| `create-test-cert` | Apply `resources/certificate.yaml` |
| `wait-for-cert` | Assert `Certificate` condition `Ready=True` |
| `deploy-test-job` | Apply `resources/test-job.yaml` |
| `wait-for-job` | Assert `Job.status.succeeded == 1` |

### Job shell script (sequential, exits non-zero on any failure)

1. `step ca health --ca-url <url> --root /root-ca/tls.crt` → assert `ok`
2. Derive fingerprint: `step certificate fingerprint /root-ca/tls.crt`
3. `step ca root <fingerprint> --ca-url <url> --root /root-ca/tls.crt` → assert cert returned
4. `step ca certificate test-intermediate /tmp/issued.crt /tmp/issued.key --provisioner x5c --x5c-cert /x5c-cert/tls.crt --x5c-key /x5c-cert/tls.key --ca-url <url> --root /root-ca/tls.crt --no-password --insecure` → assert `openssl x509 -text -noout -in /tmp/issued.crt` contains `CA:TRUE`
5. `step ca revoke --cert /tmp/issued.crt --key /tmp/issued.key --ca-url <url> --root /root-ca/tls.crt`
6. Fetch CRL: `curl --cacert /root-ca/tls.crt <url>/1.0/crl` → convert DER→PEM; extract serial from `/tmp/issued.crt`; assert serial in CRL

## Cross-Namespace Secret Access

The internal Job needs to read `csi-driver-spiffe-ca` from the `step-ca` namespace. Options:

1. **Copy Secret into test namespace during setup** — chainsaw script step copies the Secret before deploying the Job. Simple, no RBAC changes.
2. **ClusterRole granting get on the Secret** — cleaner but requires cluster-level RBAC.

Use **option 1** (copy via script step) to keep the test self-contained without cluster-wide RBAC changes.

## Running the Tests

```bash
# External suite
.venv/bin/chainsaw test tests/step-ca/external

# Internal suite
.venv/bin/chainsaw test tests/step-ca/internal

# Both
.venv/bin/chainsaw test tests/step-ca
```

## References

- [ADR-0005](../adr/0005-using-cert-manager-to-issue-spiffe-x-509-svid-certificates-for-iam-access-roles-anywhere.md) — cert-manager SPIFFE setup and key usage requirements
- [ADR-0007](../adr/0007-crossplane-composition-for-externaldns-and-certmanager-iam-roles-anywhere.md) — IAM Roles Anywhere Pattern D using step-ca X5C provisioner
- [step-ca connectivity validation](../memory/step-ca-connectivity-validation.md) — fingerprint derivation and bootstrap commands
