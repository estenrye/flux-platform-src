---
name: m3-design
description: M3 design decisions — democratic-csi swap, Garage, OpenBao, Keycloak, Pinniped — and three open [H] decisions before M3 can start
metadata:
  type: project
---

M3 design drafted 2026-07-21.
Full doc: [docs/superpowers/specs/2026-07-21-m3-identity-secrets-design.md](../superpowers/specs/2026-07-21-m3-identity-secrets-design.md)

**Why:** democratic-csi swap decided at M3 kickoff per M3 plan. Research
confirmed: truenas-csi iSCSI still blocked (kubernetes-csi/csi-lib-iscsi#94
OPEN); democratic-csi `datasetPermissions*` broken on TrueNAS 25.10.4
(democratic-csi#564 OPEN, silent race); correct NFS fix is
`fsGroupPolicy: File` + no `datasetPermissions*` (kubelet handles fsGroup).
Democratic-csi iSCSI uses a native Node.js implementation (not csi-lib-iscsi)
so it may unblock IPv6 iSCSI on the cluster.

**How to apply:** Use this as the M3 kickoff reference. Do not use
`datasetPermissions*` on democratic-csi. Do not attempt truenas-csi iSCSI.

## Key approved decisions

- **A1**: Swap to democratic-csi 0.15.1; `fsGroupPolicy: File` for NFS;
  iSCSI smoke test at step 1; retire `nfs-pg-owner` CronJob only after
  smoke test confirms CNPG fsGroup coverage. If iSCSI fails, Garage uses
  NFS instead; rest of M3 proceeds.
- **A2**: Garage before OpenBao raft snapshots. Garage admin token via SOPS
  at bootstrap (same break-glass pattern as aws-account-creds).
- **A3**: Static unseal keys (SOPS); auto-unseal deferred to M11.
- ~~**A4**~~ CORRECTED 2026-07-24: originally scoped as `aws-account-creds`
  (a static AWS bootstrap key) + one proof ESO ExternalSecret. The
  `aws-account-creds` half never had a real source: the Roles Anywhere
  trust-anchor bootstrap (M2 §4.4) was done interactively with the
  user's AWS SAML SSO credentials, not a stored static IAM key — no
  such secret was ever created, so there is nothing to migrate. Scope is
  now just the one proof-of-concept ExternalSecret. Talos machine
  secrets stay in SOPS. See [[m3-step-tracker]] step 6 pre-flight note.

## Open [H] decisions (needed before indicated steps)

- ~~**A5**~~ CLOSED: Envoy Gateway `merged-eg` HTTPS terminate + HTTPRoute +
  external-dns AAAA from GUA VIP (same as ca.rye.ninja). Certs must be
  publicly trusted (browser-facing OIDC) — Let's Encrypt DNS-01 via Cloudflare,
  new `cert-manager-acme` Kustomization with `letsencrypt-prod` +
  `letsencrypt-staging` ClusterIssuers. Reuses existing Cloudflare token
  (`cloudflare-api-token/credential` in 1Password) via ESO ExternalSecret in
  cert-manager namespace. No new Cloudflare token, no port 80 inbound needed.
- **A6** CLOSED on R2: Cloudflare R2 bucket `openbao-snapshots`, scoped API
  token in SOPS. Free egress, S3-compatible, no Crossplane dependency, no
  SPIFFE in CronJob. **[H] before step 7**: create bucket + token in
  Cloudflare dashboard, SOPS-encrypt under `clusters/controlplane/`.
- ~~**Realm/group names**~~ CLOSED: per-app model, realm `ryezone-labs`.
  M3 groups: `k8s-admin` (cluster-admin), `k8s-viewer` (view),
  `keycloak-admin` (realm-admin role), `openbao-admin` (full vault),
  `openbao-operator` (read/list secret/* only). Local Keycloak admin
  credential stored in OpenBao as break-glass. Future groups reserved
  (grafana-*, backstage-admin, dispatch-*, nats-admin, tenant-*) but not
  created until their respective milestones.

## Execution order (11 steps)

1. democratic-csi smoke test + StorageClass shadow deploy
2. Flip default SC, migrate step-ca-db, retire CronJob
3. Garage 3-node + bucket provisioning
4. step-ca-db barman → Garage (retire dump CronJob)
5. OpenBao HA raft + unseal ceremony [H]
6. ESO ClusterSecretStore → OpenBao; proof-of-concept ExternalSecret
   (aws-account-creds migration dropped — see A4 correction)
7. OpenBao raft snapshot CronJob → Garage + off-site [H: A6]
8. keycloak-db CNPG [H: group names]
9. Keycloak + exposure at id.rye.ninja [H: A5]
10. Pinniped Supervisor + Concierge [H: kubectl test]
11. ADRs (ADR-21 amendment, ADR-25, ADR-26) + runbooks

## New ADRs

- ADR-21 amendment: democratic-csi swap
- ADR-25: OpenBao secret store
- ADR-26: Keycloak + Pinniped identity
