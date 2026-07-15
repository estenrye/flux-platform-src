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

Gotchas from the workstation ([[workstation-nat64-route]]): needs the VIP
/112 host route; first connection after ND-cache expiry may stall
(asymmetric return + macOS MAC rotation) — retry once.
