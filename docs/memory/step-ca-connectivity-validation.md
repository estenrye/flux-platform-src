---
name: step-ca-connectivity-validation
description: Health check and root fingerprint validation for https://ca.rye.ninja (controlplane; fresh root, M2)
metadata:
  type: reference
---

# step-ca Connectivity Validation

Endpoint: **`https://ca.rye.ninja`** (M2 design A3 — born on the fresh
root; the old `ca.crossplane.rye.ninja` died with Spot). Envoy TLS
passthrough on the GUA VIP; LAN resolution via UniFi/split-horizon DNS64.

Root fingerprint (sha256, stable — offline 10y root, expires 2036-07-11):

```
6cdc50debddfe67e200a3ef1e18297eece9e9b68ed5bd5036dd1f4d6e211815b
```

Also pinned in `tests/platform-baseline/values/controlplane.env`.

```bash
curl -sk https://ca.rye.ninja/health
# {"status":"ok"}
curl -sk https://ca.rye.ninja/root/6cdc50debddfe67e200a3ef1e18297eece9e9b68ed5bd5036dd1f4d6e211815b
# {"ca":"-----BEGIN CERTIFICATE-----..."} — 404 on any wrong fingerprint
```

Workstation bootstrap (`step` CLI):

```bash
step ca bootstrap --ca-url https://ca.rye.ninja \
  --fingerprint 6cdc50debddfe67e200a3ef1e18297eece9e9b68ed5bd5036dd1f4d6e211815b
```

Serving chain: leaf `CN=Step Online CA` (24h) ← `CN=ryezone-labs
Intermediate CA controlplane` (1y, in-cluster) ← offline root. In-cluster
secret: `csi-driver-spiffe-ca` (cert-manager ns, ESO-mirrored to step-ca).

**Root vs. intermediate gotcha (bit three chainsaw suites, 2026-07-21):**
`csi-driver-spiffe-ca`'s `tls.crt` is the **intermediate**, not the root
(`Issuer: CN=ryezone-labs Root CA`, `Subject: CN=ryezone-labs Intermediate
CA controlplane`). Any script computing "the live root fingerprint" from
that secret is comparing the wrong cert — it'll never match the pinned
value above, and `step ca certificate --root <file>` actively rejects a
non-root file (the CA server checks the given cert's fingerprint against
what it declares as its own trusted root, not just chain validity). The
actual root, trust-manager's fleet-distributed Bundle, lives at
`configmap/ryezone-labs-root` (any namespace, key `root.crt`, plain text —
no base64 decode, unlike a Secret). Fixed in
`tests/platform-baseline/step-ca/chainsaw-test.yaml`,
`tests/step-ca/internal/chainsaw-test.yaml`, and
`tests/step-ca/external/chainsaw-test.yaml`.

Gotchas from the workstation ([[workstation-nat64-route]]): needs the VIP
/112 host route; first connection after ND-cache expiry may stall
(asymmetric return + macOS MAC rotation) — retry once.
