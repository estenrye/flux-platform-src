# step-ca SPIFFE Capability Chainsaw Tests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement two independent Kyverno Chainsaw test suites (external and internal) that validate the five step-ca SPIFFE capabilities required by ADR-0005 and ADR-0007: health, root CA fingerprint API, X5C certificate issuance, revocation, and CRL verification.

**Architecture:** Two separate chainsaw test directories — `tests/step-ca/external/` runs scripts on the test runner against `https://ca.crossplane.rye.ninja`, and `tests/step-ca/internal/` deploys a Job inside the crossplane cluster against the in-cluster service URL. Each suite creates its own cert-manager `Certificate` (plus a `CertificateRequestPolicy` and RBAC to get it approved by approver-policy) and cleans up after itself via chainsaw's built-in teardown.

**Tech Stack:** Kyverno Chainsaw 0.2.15, cert-manager, step CLI 0.30.6, `smallstep/step-cli:0.30.6` (Debian-slim base with curl installable via apt)

---

## Key Facts

- Chainsaw binary: `.venv/bin/chainsaw`
- ClusterIssuer for test cert: `csi-driver-spiffe-ca` (not `csi-driver-spiffe-issuer` — only one ClusterIssuer exists)
- The cert-manager internal auto-approver is **disabled** — every `CertificateRequest` must be covered by a `CertificateRequestPolicy`; the existing policy only covers the `selfsigned` ClusterIssuer, so the tests must deploy their own policy
- RBAC pattern: `CertificateRequestPolicy` → `ClusterRole` (verb `use`) → `ClusterRoleBinding` (subject: `cert-manager` SA in `cert-manager` ns)
- Chainsaw injects `$NAMESPACE` into script steps
- step-ca X5C provisioner name: `x5c` (from `applications/step-ca/base/values.yaml`)
- External CA URL: `https://ca.crossplane.rye.ninja`
- Internal CA URL: `https://step-certificates.step-ca.svc.cluster.local:9000`
- Root CA secret: `csi-driver-spiffe-ca` in `step-ca` ns, key `tls.crt`
- `step crl inspect` and `step certificate inspect --format json` available in step 0.30.6
- `smallstep/step-cli:0.30.6` is Debian-slim; `curl` and `openssl` must be installed via `apt-get` in the Job script

---

## File Map

| File | Action | Description |
|---|---|---|
| `tests/step-ca/external/resources/approver-policy.yaml` | Create | CertificateRequestPolicy + ClusterRole + ClusterRoleBinding for test cert |
| `tests/step-ca/external/resources/certificate.yaml` | Create | cert-manager Certificate (leaf, signed by csi-driver-spiffe-ca) |
| `tests/step-ca/external/chainsaw-test.yaml` | Create | External test: 7 steps — setup, 5 capability scripts, assert cert ready |
| `tests/step-ca/internal/resources/approver-policy.yaml` | Create | Same as external (different resource names to avoid conflicts) |
| `tests/step-ca/internal/resources/certificate.yaml` | Create | Same cert resource |
| `tests/step-ca/internal/resources/test-job.yaml` | Create | Kubernetes Job using smallstep/step-cli:0.30.6 |
| `tests/step-ca/internal/chainsaw-test.yaml` | Create | Internal test: setup, copy root CA secret, deploy Job, assert succeeded |

---

## Task 1: External test — approver-policy resources

**Files:**
- Create: `tests/step-ca/external/resources/approver-policy.yaml`

- [ ] **Step 1: Create the file**

```yaml
# tests/step-ca/external/resources/approver-policy.yaml
apiVersion: policy.cert-manager.io/v1alpha1
kind: CertificateRequestPolicy
metadata:
  name: step-ca-test-x5c-cert-policy
spec:
  allowed:
    isCA: false
    usages:
      - digital signature
  selector:
    issuerRef:
      group: cert-manager.io
      kind: ClusterIssuer
      name: csi-driver-spiffe-ca
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cert-manager-policy:step-ca-test-x5c-cert
rules:
  - apiGroups: ["policy.cert-manager.io"]
    resources: ["certificaterequestpolicies"]
    verbs: ["use"]
    resourceNames: ["step-ca-test-x5c-cert-policy"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cert-manager-policy:step-ca-test-x5c-cert
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cert-manager-policy:step-ca-test-x5c-cert
subjects:
  - kind: ServiceAccount
    name: cert-manager
    namespace: cert-manager
```

- [ ] **Step 2: Verify the file applies cleanly against the cluster**

```bash
export KUBECONFIG=~/.kube/spot/ryezone-labs/crossplane-controlplane-cluster.yaml
kubectl apply -f tests/step-ca/external/resources/approver-policy.yaml --dry-run=server
```

Expected: `certificaterequestpolicy.policy.cert-manager.io/step-ca-test-x5c-cert-policy configured (server dry run)` (and similar for ClusterRole, ClusterRoleBinding)

- [ ] **Step 3: Commit**

```bash
git add tests/step-ca/external/resources/approver-policy.yaml
git commit -m "test(step-ca): add approver-policy resources for external X5C test cert"
```

---

## Task 2: External test — Certificate resource

**Files:**
- Create: `tests/step-ca/external/resources/certificate.yaml`

- [ ] **Step 1: Create the file**

```yaml
# tests/step-ca/external/resources/certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: step-ca-x5c-test-cert
spec:
  secretName: step-ca-x5c-test-cert
  duration: 1h
  commonName: step-ca-x5c-test
  issuerRef:
    name: csi-driver-spiffe-ca
    kind: ClusterIssuer
    group: cert-manager.io
  usages:
    - digital signature
```

- [ ] **Step 2: Commit**

```bash
git add tests/step-ca/external/resources/certificate.yaml
git commit -m "test(step-ca): add cert-manager Certificate resource for external X5C test"
```

---

## Task 3: External test — chainsaw-test.yaml

**Files:**
- Create: `tests/step-ca/external/chainsaw-test.yaml`

- [ ] **Step 1: Create the file**

```yaml
# tests/step-ca/external/chainsaw-test.yaml
apiVersion: chainsaw.kyverno.io/v1alpha1
kind: Test
metadata:
  name: step-ca-external
spec:
  steps:
    - name: apply-approver-policy
      try:
        - apply:
            file: resources/approver-policy.yaml

    - name: create-test-cert
      try:
        - apply:
            file: resources/certificate.yaml

    - name: wait-for-cert
      try:
        - assert:
            timeout: 60s
            resource:
              apiVersion: cert-manager.io/v1
              kind: Certificate
              metadata:
                name: step-ca-x5c-test-cert
              status:
                conditions:
                  - type: Ready
                    status: "True"

    - name: health
      try:
        - script:
            content: |
              set -e
              RESPONSE=$(curl -sk https://ca.crossplane.rye.ninja/health)
              echo "Response: $RESPONSE"
              echo "$RESPONSE" | grep -q '"status":"ok"'
              echo "health: ok"

    - name: root-ca
      try:
        - script:
            content: |
              set -e
              export KUBECONFIG=~/.kube/spot/ryezone-labs/crossplane-controlplane-cluster.yaml
              FINGERPRINT=$(kubectl get secret csi-driver-spiffe-ca -n step-ca \
                -o jsonpath='{.data.tls\.crt}' | base64 -d \
                | openssl x509 -noout -fingerprint -sha256 \
                | sed 's/.*=//;s/://g' | tr '[:upper:]' '[:lower:]')
              echo "Fingerprint: $FINGERPRINT"
              RESPONSE=$(curl -sk "https://ca.crossplane.rye.ninja/root/${FINGERPRINT}")
              echo "Response: $RESPONSE"
              echo "$RESPONSE" | grep -q '"ca"'
              echo "root-ca: ok"

    - name: x5c-provisioner
      try:
        - script:
            content: |
              set -e
              export KUBECONFIG=~/.kube/spot/ryezone-labs/crossplane-controlplane-cluster.yaml
              # Extract root CA cert for TLS validation and X5C auth cert/key
              kubectl get secret csi-driver-spiffe-ca -n step-ca \
                -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/root-ca-${NAMESPACE}.crt
              kubectl get secret step-ca-x5c-test-cert -n ${NAMESPACE} \
                -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/x5c-${NAMESPACE}.crt
              kubectl get secret step-ca-x5c-test-cert -n ${NAMESPACE} \
                -o jsonpath='{.data.tls\.key}' | base64 -d > /tmp/x5c-${NAMESPACE}.key
              # Issue intermediate CA cert via X5C provisioner
              .venv/bin/step ca certificate "step-ca-test-intermediate" \
                /tmp/issued-${NAMESPACE}.crt \
                /tmp/issued-${NAMESPACE}.key \
                --provisioner x5c \
                --x5c-cert /tmp/x5c-${NAMESPACE}.crt \
                --x5c-key /tmp/x5c-${NAMESPACE}.key \
                --ca-url https://ca.crossplane.rye.ninja \
                --root /tmp/root-ca-${NAMESPACE}.crt \
                --no-password
              # Assert issued cert is a CA cert
              openssl x509 -text -noout -in /tmp/issued-${NAMESPACE}.crt | grep -q 'CA:TRUE'
              echo "x5c-provisioner: ok"

    - name: revoke
      try:
        - script:
            content: |
              set -e
              .venv/bin/step ca revoke \
                --cert /tmp/issued-${NAMESPACE}.crt \
                --key /tmp/issued-${NAMESPACE}.key \
                --ca-url https://ca.crossplane.rye.ninja \
                --root /tmp/root-ca-${NAMESPACE}.crt
              echo "revocation: ok"

    - name: crl-contains-revoked
      try:
        - script:
            content: |
              set -e
              # Extract serial from revoked cert
              SERIAL=$(openssl x509 -serial -noout -in /tmp/issued-${NAMESPACE}.crt | sed 's/serial=//')
              echo "Revoked serial: $SERIAL"
              # Fetch CRL (DER) and convert to text, check serial appears
              curl -sk https://ca.crossplane.rye.ninja/1.0/crl -o /tmp/crl-${NAMESPACE}.der
              openssl crl -inform DER -text -noout -in /tmp/crl-${NAMESPACE}.der | grep -qi "$SERIAL"
              echo "crl-contains-revoked: ok"
```

- [ ] **Step 2: Run the external test suite**

```bash
export KUBECONFIG=~/.kube/spot/ryezone-labs/crossplane-controlplane-cluster.yaml
.venv/bin/chainsaw test tests/step-ca/external
```

Expected output (all steps pass):
```
--- PASS: step-ca-external (Xs)
    --- PASS: step-ca-external/apply-approver-policy
    --- PASS: step-ca-external/create-test-cert
    --- PASS: step-ca-external/wait-for-cert
    --- PASS: step-ca-external/health
    --- PASS: step-ca-external/root-ca
    --- PASS: step-ca-external/x5c-provisioner
    --- PASS: step-ca-external/revoke
    --- PASS: step-ca-external/crl-contains-revoked
```

If `wait-for-cert` times out: check `kubectl get certificaterequest -n $NAMESPACE` — if status is Denied, the CertificateRequestPolicy in Task 1 may need adjustment (check `kubectl describe certificaterequest -n $NAMESPACE`).

- [ ] **Step 3: Commit**

```bash
git add tests/step-ca/external/chainsaw-test.yaml
git commit -m "test(step-ca): add external chainsaw test suite for SPIFFE capabilities"
```

---

## Task 4: Internal test — approver-policy resources

**Files:**
- Create: `tests/step-ca/internal/resources/approver-policy.yaml`

- [ ] **Step 1: Create the file**

Uses different resource names (`step-ca-internal-test-x5c-cert-policy`) to avoid conflict with the external test policy when both run simultaneously.

```yaml
# tests/step-ca/internal/resources/approver-policy.yaml
apiVersion: policy.cert-manager.io/v1alpha1
kind: CertificateRequestPolicy
metadata:
  name: step-ca-internal-test-x5c-cert-policy
spec:
  allowed:
    isCA: false
    usages:
      - digital signature
  selector:
    issuerRef:
      group: cert-manager.io
      kind: ClusterIssuer
      name: csi-driver-spiffe-ca
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cert-manager-policy:step-ca-internal-test-x5c-cert
rules:
  - apiGroups: ["policy.cert-manager.io"]
    resources: ["certificaterequestpolicies"]
    verbs: ["use"]
    resourceNames: ["step-ca-internal-test-x5c-cert-policy"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cert-manager-policy:step-ca-internal-test-x5c-cert
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cert-manager-policy:step-ca-internal-test-x5c-cert
subjects:
  - kind: ServiceAccount
    name: cert-manager
    namespace: cert-manager
```

- [ ] **Step 2: Commit**

```bash
git add tests/step-ca/internal/resources/approver-policy.yaml
git commit -m "test(step-ca): add approver-policy resources for internal X5C test cert"
```

---

## Task 5: Internal test — Certificate resource

**Files:**
- Create: `tests/step-ca/internal/resources/certificate.yaml`

- [ ] **Step 1: Create the file**

```yaml
# tests/step-ca/internal/resources/certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: step-ca-x5c-test-cert
spec:
  secretName: step-ca-x5c-test-cert
  duration: 1h
  commonName: step-ca-x5c-test
  issuerRef:
    name: csi-driver-spiffe-ca
    kind: ClusterIssuer
    group: cert-manager.io
  usages:
    - digital signature
```

- [ ] **Step 2: Commit**

```bash
git add tests/step-ca/internal/resources/certificate.yaml
git commit -m "test(step-ca): add cert-manager Certificate resource for internal X5C test"
```

---

## Task 6: Internal test — Job resource

**Files:**
- Create: `tests/step-ca/internal/resources/test-job.yaml`

The Job uses `smallstep/step-cli:0.30.6` (Debian-slim base). It installs `curl` and `openssl` via `apt-get` at startup, then runs all five capability checks sequentially. The Job exits non-zero on any failure, which chainsaw detects via `Job.status.succeeded`.

The root CA secret is copied into the test namespace by a chainsaw `script` step before the Job is deployed (see Task 7). It lands as a Secret named `root-ca` in `$NAMESPACE` and is mounted at `/root-ca`.

- [ ] **Step 1: Create the file**

```yaml
# tests/step-ca/internal/resources/test-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: step-ca-capability-test
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      volumes:
        - name: x5c-cert
          secret:
            secretName: step-ca-x5c-test-cert
        - name: root-ca
          secret:
            secretName: root-ca
      containers:
        - name: test
          image: smallstep/step-cli:0.30.6
          command: ["/bin/sh", "-exc"]
          args:
            - |
              apt-get update -qq && apt-get install -y -qq curl openssl

              CA_URL=https://step-certificates.step-ca.svc.cluster.local:9000
              ROOT_CERT=/root-ca/tls.crt

              # 1. Health check
              step ca health --ca-url "$CA_URL" --root "$ROOT_CERT"
              echo "health: ok"

              # 2. Root CA fingerprint API
              FINGERPRINT=$(step certificate fingerprint "$ROOT_CERT" | sed 's/://g' | tr '[:upper:]' '[:lower:]')
              echo "Fingerprint: $FINGERPRINT"
              step ca root /tmp/root-fetched.crt \
                --fingerprint "$FINGERPRINT" \
                --ca-url "$CA_URL" \
                --root "$ROOT_CERT"
              FETCHED_FP=$(step certificate fingerprint /tmp/root-fetched.crt | sed 's/://g' | tr '[:upper:]' '[:lower:]')
              test "$FINGERPRINT" = "$FETCHED_FP"
              echo "root-ca: ok"

              # 3. X5C provisioner — issue intermediate CA cert
              step ca certificate "step-ca-test-intermediate" /tmp/issued.crt /tmp/issued.key \
                --provisioner x5c \
                --x5c-cert /x5c-cert/tls.crt \
                --x5c-key /x5c-cert/tls.key \
                --ca-url "$CA_URL" \
                --root "$ROOT_CERT" \
                --no-password
              openssl x509 -text -noout -in /tmp/issued.crt | grep -q 'CA:TRUE'
              echo "x5c-provisioner: ok"

              # 4. Revoke the issued cert
              step ca revoke \
                --cert /tmp/issued.crt \
                --key /tmp/issued.key \
                --ca-url "$CA_URL" \
                --root "$ROOT_CERT"
              echo "revocation: ok"

              # 5. CRL contains revoked serial
              SERIAL=$(openssl x509 -serial -noout -in /tmp/issued.crt | sed 's/serial=//')
              echo "Revoked serial: $SERIAL"
              curl --cacert "$ROOT_CERT" "$CA_URL/1.0/crl" -o /tmp/crl.der
              openssl crl -inform DER -text -noout -in /tmp/crl.der | grep -qi "$SERIAL"
              echo "crl-contains-revoked: ok"

              echo "ALL CHECKS PASSED"
          volumeMounts:
            - name: x5c-cert
              mountPath: /x5c-cert
              readOnly: true
            - name: root-ca
              mountPath: /root-ca
              readOnly: true
```

- [ ] **Step 2: Commit**

```bash
git add tests/step-ca/internal/resources/test-job.yaml
git commit -m "test(step-ca): add internal step-ca capability test Job"
```

---

## Task 7: Internal test — chainsaw-test.yaml

**Files:**
- Create: `tests/step-ca/internal/chainsaw-test.yaml`

- [ ] **Step 1: Create the file**

```yaml
# tests/step-ca/internal/chainsaw-test.yaml
apiVersion: chainsaw.kyverno.io/v1alpha1
kind: Test
metadata:
  name: step-ca-internal
spec:
  steps:
    - name: apply-approver-policy
      try:
        - apply:
            file: resources/approver-policy.yaml

    - name: create-test-cert
      try:
        - apply:
            file: resources/certificate.yaml

    - name: wait-for-cert
      try:
        - assert:
            timeout: 60s
            resource:
              apiVersion: cert-manager.io/v1
              kind: Certificate
              metadata:
                name: step-ca-x5c-test-cert
              status:
                conditions:
                  - type: Ready
                    status: "True"

    - name: copy-root-ca-secret
      try:
        - script:
            content: |
              set -e
              export KUBECONFIG=~/.kube/spot/ryezone-labs/crossplane-controlplane-cluster.yaml
              kubectl get secret csi-driver-spiffe-ca -n step-ca -o json \
                | jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.ownerReferences, .metadata.annotations) | .metadata.name = "root-ca" | .metadata.namespace = "'${NAMESPACE}'"' \
                | kubectl apply -f -
              echo "root-ca secret copied to $NAMESPACE"

    - name: deploy-test-job
      try:
        - apply:
            file: resources/test-job.yaml

    - name: wait-for-job
      try:
        - assert:
            timeout: 120s
            resource:
              apiVersion: batch/v1
              kind: Job
              metadata:
                name: step-ca-capability-test
              status:
                succeeded: 1
```

- [ ] **Step 2: Run the internal test suite**

```bash
export KUBECONFIG=~/.kube/spot/ryezone-labs/crossplane-controlplane-cluster.yaml
.venv/bin/chainsaw test tests/step-ca/internal
```

Expected output:
```
--- PASS: step-ca-internal (Xs)
    --- PASS: step-ca-internal/apply-approver-policy
    --- PASS: step-ca-internal/create-test-cert
    --- PASS: step-ca-internal/wait-for-cert
    --- PASS: step-ca-internal/copy-root-ca-secret
    --- PASS: step-ca-internal/deploy-test-job
    --- PASS: step-ca-internal/wait-for-job
```

If `wait-for-job` times out, check job logs: `kubectl logs -n $NAMESPACE job/step-ca-capability-test`

If the Job fails at the `apt-get` step, the `smallstep/step-cli:0.30.6` image may not support `apt-get`. In that case, replace `apt-get update -qq && apt-get install -y -qq curl openssl` with the equivalent `apk add --no-cache curl openssl` (if Alpine-based).

- [ ] **Step 3: Run both suites together to confirm isolation**

```bash
export KUBECONFIG=~/.kube/spot/ryezone-labs/crossplane-controlplane-cluster.yaml
.venv/bin/chainsaw test tests/step-ca
```

Expected: both `step-ca-external` and `step-ca-internal` pass.

- [ ] **Step 4: Commit**

```bash
git add tests/step-ca/internal/chainsaw-test.yaml
git commit -m "test(step-ca): add internal chainsaw test suite for SPIFFE capabilities"
```

---

## Self-Review

**Spec coverage check:**
- Health endpoint ✓ (external: `health` step; internal: Job step 1)
- Root CA fingerprint API ✓ (external: `root-ca` step; internal: Job step 2, verifies fetched cert fingerprint matches)
- X5C provisioner — issue intermediate CA cert ✓ (external: `x5c-provisioner`; internal: Job step 3)
- Certificate revocation ✓ (external: `revoke`; internal: Job step 4)
- CRL contains revoked serial ✓ (external: `crl-contains-revoked`; internal: Job step 5)
- approver-policy requirement ✓ (Task 1 and Task 4)
- Cross-namespace secret copy for internal test ✓ (Task 7 `copy-root-ca-secret` step)

**Placeholder scan:** None found. All steps contain complete YAML/commands.

**Type consistency:** Resource names are consistent within each suite. External policy: `step-ca-test-x5c-cert-policy`. Internal policy: `step-ca-internal-test-x5c-cert-policy`. Secret names, job names, and cert names are consistent within each file set.
