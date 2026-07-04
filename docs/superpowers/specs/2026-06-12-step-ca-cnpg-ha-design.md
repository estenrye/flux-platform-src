# Design: HA step-ca backed by CNPG Postgres

Date: 2026-06-12

## Context

ADR-7 (Pattern D) decided that step-ca with the X5C provisioner is the signing authority for intermediate CA
certificates on workload clusters. step-ca runs on the crossplane cluster, uses the `csi-driver-spiffe-ca`
cert-manager Certificate as its root CA, and exposes a CRL endpoint that AWS IAM Roles Anywhere uses for
revocation checking (ADR-15).

This spec covers deploying step-ca in a highly available configuration, backed by a highly available Postgres
database managed by the CloudNativePG (CNPG) operator, and exposed via Envoy Gateway using the Gateway API.

All four new applications follow the existing `applications/<name>/base/` pattern and are wired into
`clusters/crossplane/kustomization.yaml`.

## Four New Flux Applications

| Application | Namespace | Purpose |
|---|---|---|
| `cnpg` | `cnpg-system` | CNPG operator + CRDs |
| `envoy-gateway` | `envoy-gateway-system` | Envoy Gateway controller + GatewayClass |
| `step-ca-db` | `step-ca` | CNPG `Cluster` resource (HA Postgres for step-ca) |
| `step-ca` | `step-ca` | step-ca Helm deployment + Gateway + routes |

`step-ca-db` and `step-ca` share the `step-ca` namespace so the CNPG-managed Postgres service is reachable
without cross-namespace service references.

## Ordering in `clusters/crossplane/kustomization.yaml`

The four applications are inserted after the existing cert-manager block and before crossplane:

```
# existing
../../applications/gateway-api-crds/base
../../applications/cert-manager/base
../../applications/cert-manager-approver-policy/base
../../applications/cert-manager-spiffe-issuer/base
../../applications/cert-manager-trust-manager/base
../../applications/cert-manager-spiffe-csi-driver/base

# new
../../applications/cnpg/base
../../applications/envoy-gateway/base
../../applications/step-ca-db/base
../../applications/step-ca/base

# existing
../../applications/crossplane/base
...
```

Ordering provides implicit dependency sequencing within the single `flux-platform` Kustomization:
- `cnpg` before `step-ca-db` (CRDs before CR)
- `gateway-api-crds` before `envoy-gateway` (CRDs before controller)
- `envoy-gateway` and `step-ca-db` before `step-ca` (Gateway resources + DB before the app)
- `cert-manager-spiffe-issuer` before `step-ca` (root CA Secret must exist)

## Application: `cnpg`

**Path:** `applications/cnpg/base/`

**Chart:** `oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg` — pinned version, image digests in
`kustomization.yaml`.

**Structure:**
```
kustomization.yaml   — helmCharts + namespace resource + deployment patches
values.yaml          — Helm values (defaults sufficient)
catalog.yaml         — Backstage Component
resources/
  namespace.yaml     — Namespace: cnpg-system
patches/
  deployment.yaml    — drop capabilities, read-only root fs, seccomp RuntimeDefault
```

No non-default Helm values are required. The hardening patches apply the standard security posture used by
all other applications in this repo.

## Application: `envoy-gateway`

**Path:** `applications/envoy-gateway/base/`

**Chart:** `oci://docker.io/envoyproxy/gateway-helm` — pinned version, image digests.

**Structure:**
```
kustomization.yaml
values.yaml
catalog.yaml         — Backstage Component
resources/
  namespace.yaml                        — Namespace: envoy-gateway-system
  custom-proxy-config.envoyproxy.yaml   — EnvoyProxy CR (mergeGateways: true)
  merged-eg.gatewayclass.yaml           — GatewayClass referencing custom-proxy-config
patches/
  deployment.yaml    — standard hardening
```

**`EnvoyProxy` CR** (`envoy-gateway-system` namespace):
```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: custom-proxy-config
  namespace: envoy-gateway-system
spec:
  mergeGateways: true
```

**`GatewayClass`** (cluster-scoped):
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: merged-eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: custom-proxy-config
    namespace: envoy-gateway-system
```

`mergeGateways: true` causes all `Gateway` resources referencing `merged-eg` to be served by a single shared
Envoy proxy fleet rather than a dedicated proxy per Gateway. The `GatewayClass` is platform-scoped and lives
here; application-specific `Gateway` and route resources live in each consumer application.

## Application: `step-ca-db`

**Path:** `applications/step-ca-db/base/`

**Structure:**
```
kustomization.yaml
catalog.yaml         — Backstage Component
resources/
  namespace.yaml            — Namespace: step-ca
  network-policy.yaml       — restrict port 5432 ingress to step-ca pods only
  step-ca-db.cluster.yaml   — CNPG Cluster resource
```

No Helm chart — the CNPG `Cluster` is a plain CR.

**CNPG `Cluster` resource:**

| Field | Value | Rationale |
|---|---|---|
| `instances` | `3` | 1 primary + 2 standbys; survives single-node failure |
| `postgresql.parameters.max_connections` | `100` | sufficient for step-ca's small connection pool |
| `storage.size` | `10Gi` | minimum PVC size on Rackspace Spot; step-ca's actual data footprint is small |
| `bootstrap.initdb.database` | `stepcas` | step-ca's conventional DB name |
| `bootstrap.initdb.owner` | `stepcas` | CNPG auto-creates `<cluster-name>-app` Secret |
| `primaryUpdateStrategy` | `unsupervised` | allows automated failover during upgrades |
| `monitoring.enablePodMonitor` | `true` | consistent with existing Prometheus setup |

CNPG automatically creates in the `step-ca` namespace:
- `<cluster-name>-superuser` Secret — DBA credentials
- `<cluster-name>-app` Secret — application credentials (used by step-ca)
- `<cluster-name>-rw` Service — always routes to the primary (step-ca connects here)
- `<cluster-name>-ro` Service — round-robin across standbys

**NetworkPolicy:** ingress on port 5432 restricted to pods with
`app.kubernetes.io/name: step-certificates` in the `step-ca` namespace.

## Application: `step-ca`

**Path:** `applications/step-ca/base/`

**Chart:** `step-certificates` from the smallstep Helm repo — pinned version, image digests.

**Structure:**
```
kustomization.yaml   — no global namespace: field (cross-namespace resources)
values.yaml
catalog.yaml         — Backstage Component
resources/
  network-policy.yaml                    — ingress from Envoy proxy; egress to CNPG RW
  eso.service-account.yaml               — ServiceAccount: step-ca-cert-reader (step-ca ns)
  eso.cert-manager-role.yaml             — Role in cert-manager ns: get csi-driver-spiffe-ca
  eso.cert-manager-rolebinding.yaml      — binds step-ca-cert-reader SA to the Role
  eso.secret-store.yaml                  — SecretStore (Kubernetes provider, cert-manager ns)
  eso.external-secret.yaml               — mirrors csi-driver-spiffe-ca → step-ca ns
  gateway.yaml                           — Gateway (merged-eg, listeners: 443 passthrough + 80 HTTP)
  tls-route.yaml                         — TLSRoute → step-certificates port 9000
  http-route.yaml                        — HTTPRoute /1.0/crl → step-certificates port 9001
patches/
  deployment.yaml    — standard hardening
```

Because this application has resources in both the `step-ca` and `cert-manager` namespaces (for the ESO
RBAC), the `kustomization.yaml` does **not** set a global `namespace:` field. Every resource file declares
its own `metadata.namespace` explicitly.

### Root CA Key Material — ESO Kubernetes Provider

step-ca needs the `csi-driver-spiffe-ca` TLS Secret (cert + private key) that cert-manager manages in the
`cert-manager` namespace. ESO's Kubernetes provider is used to sync it into the `step-ca` namespace:

1. `ServiceAccount` `step-ca-cert-reader` in `step-ca` namespace
2. `Role` in `cert-manager` namespace: `get` on Secret `csi-driver-spiffe-ca`
3. `RoleBinding` in `cert-manager` namespace: binds `step-ca-cert-reader` to the Role
4. `SecretStore` in `step-ca` namespace: Kubernetes provider, `remoteNamespace: cert-manager`,
   authenticating as `step-ca-cert-reader`
5. `ExternalSecret` in `step-ca` namespace: projects `tls.crt` and `tls.key` from
   `csi-driver-spiffe-ca` into a new Secret named `csi-driver-spiffe-ca` in the `step-ca` namespace

The `refreshInterval` on the ExternalSecret is set to `1h`, matching cert-manager's renewal polling cadence.
When cert-manager rotates the root CA, ESO picks up the new cert and key within one hour and updates the
Secret, triggering a step-ca pod rollout via Reloader (already deployed on the cluster).

### HA Configuration

`replicaCount: 2`. step-ca supports multiple replicas when the database backend is Postgres — all replicas
connect to the CNPG `<cluster-name>-rw` Service, which always points to the primary.

### Provisioner Configuration

The X5C provisioner is configured per ADR-7 Pattern D. The provisioner trusts the root CA
(`csi-driver-spiffe-ca`) and enforces via certificate templates:
- `isCA: true`, `maxPathLen: 0` on issued intermediate CA certificates
- CRL distribution point extension pointing to step-ca's `/1.0/crl` HTTP endpoint

### Gateway Resources

**`Gateway`** (in `step-ca` namespace, `GatewayClass: merged-eg`):

| Listener | Port | Protocol | TLS Mode |
|---|---|---|---|
| `https-passthrough` | 443 | TLS | Passthrough — step-ca owns its TLS |
| `http-crl` | 80 | HTTP | — |

The Gateway hostname is left unset in `base/` and provided via a cluster-specific patch in
`clusters/crossplane/` (e.g. `ca.crossplane.rye.ninja`).

**`TLSRoute`:** routes port 443 passthrough traffic to the `step-certificates` Service on port 9000
(step-ca's secure server — CA API used by step-issuer on workload clusters).

**`HTTPRoute`:** routes port 80 traffic matching path `/1.0/crl` to the `step-certificates` Service on
port 9001 (step-ca's insecure server — CRL endpoint must be served over plain HTTP per RFC 5280).

**NetworkPolicy:**
- Ingress on ports 9000 and 9001 from pods in `envoy-gateway-system` namespace
- Egress on port 5432 to the `step-ca-db` CNPG RW Service in `step-ca` namespace
- Egress on port 443 to the Kubernetes API (for ESO Kubernetes provider token exchange)

## Cluster-Specific Patch (`clusters/crossplane/`)

A patch file in `clusters/crossplane/` sets the Gateway hostname:

```yaml
# clusters/crossplane/patches/step-ca.gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: step-ca
  namespace: step-ca
spec:
  listeners:
    - name: https-passthrough
      hostname: ca.crossplane.rye.ninja
    - name: http-crl
      hostname: ca.crossplane.rye.ninja
```

## References

- [ADR-7: Crossplane Composition — Pattern D deep-dive (step-ca)](../adr/0007-crossplane-composition-for-externaldns-and-certmanager-iam-roles-anywhere.md)
- [ADR-15: Secret and Certificate Rotation Strategy](../adr/0015-secret-and-certificate-rotation-strategy.md)
- [ADR-16: SPIFFE Trust Domain Configuration per Cluster](../adr/0016-spiffe-trust-domain-configuration-per-cluster.md)
- [CloudNativePG documentation](https://cloudnative-pg.io/documentation/)
- [step-ca Helm chart](https://smallstep.com/docs/step-ca/helm/)
- [step-ca provisioners — X5C](https://smallstep.com/docs/step-ca/provisioners/#x5c)
- [Envoy Gateway — mergeGateways](https://gateway.envoyproxy.io/docs/api/extension_types/#mergegatewaystype)
- [ESO Kubernetes provider](https://external-secrets.io/latest/provider/kubernetes/)
- [Gateway API — TLSRoute](https://gateway-api.sigs.k8s.io/reference/spec/#gateway.networking.k8s.io/v1alpha2.TLSRoute)
