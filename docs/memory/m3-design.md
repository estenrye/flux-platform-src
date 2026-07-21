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
- **A4**: Secret migration scope: only `aws-account-creds` + one proof ESO
  ExternalSecret. Talos machine secrets stay in SOPS.

## Open [H] decisions (needed before indicated steps)

- **A5** (before step 9): public exposure for `id.rye.ninja` / `sso.rye.ninja`
  — UniFi port-forward (existing pattern) vs Cloudflare Tunnel (cleaner for M6+)
- **A6** (before step 7): off-site OpenBao snapshot destination
  — Cloudflare R2 (recommended, pattern established) vs AWS S3
- **Realm/group names** (before step 8): confirm `platform-admin`, `viewer`,
  tenant group naming — baked into declarative config, hard to rename post-Pinniped RBAC

## Execution order (11 steps)

1. democratic-csi smoke test + StorageClass shadow deploy
2. Flip default SC, migrate step-ca-db, retire CronJob
3. Garage 3-node + bucket provisioning
4. step-ca-db barman → Garage (retire dump CronJob)
5. OpenBao HA raft + unseal ceremony [H]
6. ESO ClusterSecretStore → OpenBao; migrate aws-account-creds
7. OpenBao raft snapshot CronJob → Garage + off-site [H: A6]
8. keycloak-db CNPG [H: group names]
9. Keycloak + exposure at id.rye.ninja [H: A5]
10. Pinniped Supervisor + Concierge [H: kubectl test]
11. ADRs (ADR-21 amendment, ADR-25, ADR-26) + runbooks

## New ADRs

- ADR-21 amendment: democratic-csi swap
- ADR-25: OpenBao secret store
- ADR-26: Keycloak + Pinniped identity
