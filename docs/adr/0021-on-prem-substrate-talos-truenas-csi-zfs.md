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
