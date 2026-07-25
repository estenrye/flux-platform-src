# 21. On-Prem Substrate: Talos + truenas-csi + ZFS

Date: 2026-07-12

## Status

Accepted

## Context

On-prem clusters need a repeatable substrate answer for compute, storage,
and disaster recovery — the on-prem analogue of what EKS/GKE compositions
provide in cloud (ADR-14). Storage is the hard part: the home lab's
persistent data lives on a TrueNAS SCALE 25.10 system (`nas.rye.ninja`,
`flash-pool`, SAS SSD), and TrueNAS 25.x deprecated its REST API in favor
of JSON-RPC over websocket — which broke assumptions in the long-standing
community driver (democratic-csi's `freenas-api-*` drivers).

## Decision

The on-prem substrate is:

- **Compute**: Talos VMs on KVM hosts, zvol-backed on a host-local ZFS
  mirror (`vmpool`), provisioned via OpenTofu + libvirt (`providers/kvm/`).
- **In-cluster storage**: the **official TrueNAS CSI driver**
  (`truenas/truenas-csi`, JSON-RPC native) — chosen over democratic-csi to
  eliminate the 25.x API-compatibility risk. StorageClasses `truenas-iscsi`
  (default, RWO) and `truenas-nfs` (RWX); volumes land under
  `flash-pool/k8s/<cluster>/{iscsi-v,nfs-v}` via the `datasetPath`
  parameter. Storage data paths address the NAS by its **static ULA**
  (renumber-immune); only the driver's websocket API call uses the DNS name.
- **DR layering** (restore-critical first): etcd snapshots every 6 h to a
  TrueNAS NFS export; SOPS-encrypted machine secrets in git; PVC data lives
  on TrueNAS natively; nightly `zfs send` replication of VM zvols to
  TrueNAS is the convenience layer that turns "rebuild the cluster" into
  "roll back the zvols".

## Consequences

- TrueNAS is the storage SPOF for on-prem clusters; its maintenance has a
  runbook (`docs/runbooks/truenas-maintenance.md`) and its API credential
  is a per-cluster SOPS secret minted for a dedicated Full Admin user.
- iSCSI over IPv6 requires the `iscsi-tools` Talos extension — part of the
  pinned image schematic, not an afterthought.
- The driver is new (v1.1.1); the storage baseline suite is the contract
  that catches regressions, and democratic-csi remains a documented
  fallback if the official driver disappoints.
- A second on-prem cluster reuses everything with a new dataset subtree
  and its own API key.

## Amendment 2026-07-25 (democratic-csi replaces truenas-csi for iSCSI; M3 A1)

The official TrueNAS CSI driver decision above is **superseded for iSCSI**.
Full design: [2026-07-21-m3-identity-secrets-design.md](../superpowers/specs/2026-07-21-m3-identity-secrets-design.md) §A1.

- **truenas-csi iSCSI never became usable.** kubernetes-csi/csi-lib-iscsi#94
  (IPv6 portal mis-parse) stayed open and unfixed on master; truenas-csi
  pins a pre-fix version with no workaround that doesn't require upstream
  action. This cluster is IPv6-only (ADR-23), so iSCSI stayed blocked for
  the driver's entire tenure here.
- **The replacement, democratic-csi, has its own known-broken feature**:
  `datasetPermissions*` silently coalesces `setperm` calls under concurrent
  PVC creation on this TrueNAS version (SCALE 25.10.x), leaving some
  datasets `root:root 0755` while the API reports success
  (democratic-csi#564). **Do not use `datasetPermissions*`.** The
  workaround, confirmed by the issue's author running the same environment:
  `csiDriver.fsGroupPolicy: File` with no `datasetPermissions*` — kubelet
  applies `fsGroup` per-pod at mount time, and CNPG already sets
  `fsGroup: 26` natively, so Postgres volumes work with no driver-side
  chown at all. This retired the `nfs-pg-owner` CronJob bridge that
  previously plugged this exact gap.
- **democratic-csi iSCSI uses a different code path** (native Node.js, not
  `csi-lib-iscsi`) and was the actual motivation for the swap — it's the
  only route to iSCSI on this substrate. Confirmed working post-cutover:
  `democratic-csi-iscsi` backs Garage's 3-node StatefulSet (`data`/`meta`
  PVCs per replica).
- **Result**: `democratic-csi-nfs` is now the default StorageClass;
  `democratic-csi-nfs-pg` (CNPG workloads) and `democratic-csi-iscsi`
  (Garage) round out the set. The original `truenas-iscsi`/`truenas-nfs`/
  `truenas-nfs-pg` StorageClasses are left in place, unused, rather than
  deleted outright — TrueNAS itself is unaffected (still the ADR's storage
  substrate; only the CSI driver in front of it changed for these three
  classes), and removing dormant StorageClasses is a separate, low-risk
  cleanup that doesn't need to block this amendment.
- **Chart/image**: `democratic-csi` Helm chart `0.15.1`, driver image
  digest-pinned to a `next` tag (no versioned tag exists for the driver
  itself, per upstream's own release practice at the time).
