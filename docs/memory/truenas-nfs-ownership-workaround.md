---
name: truenas-nfs-ownership-workaround
description: truenas-csi cannot provision NFS volumes non-root workloads can bootstrap into; chown hook bridges it; democratic-csi swap decision due at M3 kickoff
metadata:
  type: project
---

truenas-csi (≤ v1.1.1) hardcodes NFS `mapall` (default root:wheel;
`nfs.mapAllUser` SC param only changes the target — upstream issue #4) and
creates dataset roots as root:755 with no chown/setperm at CreateVolume.
Consequence: a mapall'd non-root client (postgres uid 26 on
`truenas-nfs-pg`) cannot create anything at the volume root, and mapall
also defeats kubelet fsGroup chown. Found in M2 step 3
(`initdb: Permission denied` after the mapall fix moved it past
`wrong ownership`).

**Bridge (option A, live):** `nfs-pg-owner` CronJob in
`applications/truenas-csi/base/` — every 5 min, chowns dataset roots of
PVs whose `nfs.mapAllUser` matches, via JSON-RPC `filesystem.chown`
(probe confirmed it and `filesystem.setperm` exist and work with the
Full-Admin key; see [[truenas-api-surface]]). NAS user `k8s-postgres`
uid/gid 26 must exist.

**Upstream (option B):** filed 2026-07-14 —
https://github.com/truenas/truenas-csi/issues/47 (CreateVolume-time chown
or maproot support; `MapRootUser` field exists in the client struct,
unused; clone path omits mapall entirely).

**Swap candidate (option C), decide at M3 kickoff** before keycloak-db:
democratic-csi has native `datasetPermissions*` (solves this class), and
its maintainer confirmed TrueNAS 25.04/25.10 support on the mutable
`next` tag with a release pending (issue democratic-csi#532). If a
digest-pinnable release exists by M3, move `truenas-nfs-pg` to it and
retire the hook + NAS-user hack; if truenas-csi fixes upstream first,
keep the driver and retire just the hook.

**Shape decision (settled 2026-07-15, don't re-litigate at M3):** a
mutating webhook on PV admission was considered and rejected — nothing to
mutate (the need is an external NAS side effect, an admission
antipattern; Flux dry-runs the whole inventory every reconcile), 10s
admission window vs async `filesystem.chown` middleware jobs, and a
fail-closed webhook on PV creation recreates the ESO webhook/Flux
deadlock from M2 step 3 at the platform's most foundational layer (its
TLS cert would also need cert-manager, which sits *above* this storage
in the bootstrap order). The 5-min CronJob window only bites during
initial provisioning of a postgres cluster (CNPG initdb retries absorb
it). If the window ever demonstrably hurts before the bridge is retired,
the upgrade is the same script as a watch-loop Deployment — never
admission.
