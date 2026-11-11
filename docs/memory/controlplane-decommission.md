---
name: controlplane-decommission
description: The controlplane cluster (Talos on KVM, Crossplane/step-ca/OpenBao/Garage) and its AWS/Cloudflare/NAS/KVM resources were decommissioned 2026-11-11; order, what was removed, what was deliberately kept, and leftovers
metadata:
  type: project
---

Decommissioned 2026-11-11 (nothing was preserved; all data confirmed disposable). It was already degraded — storage
drivers crash-looping, step-ca/OpenBao/Garage down since the 2026-11-05 NAS outage — and core-infra had no live
dependency on it. Follows [[observability-decommission]]. Context: [[core-infra-nfs-outage-2026-11]].

**Order (freeze first, destroy second).** Flux suspended and Crossplane MRs set observe-only/paused so nothing
re-created resources, then:
1. AWS: delegated Route53 zone, Roles Anywhere profile/trust anchor/role/policy, CloudFormation stacks (trust-anchor
   stack before the Lambda stack), inert IAM user. Final audit found nothing left.
2. Cloudflare: NS delegation and controlplane-owned DNS records (TXT owner match, never by name pattern).
3. R2: buckets `openbao-snapshots`, `step-ca-db-snapshots`, `rye-ninja-k3s-archive` (emptied first) and tokens
   `controlplane-openbao-snapshots-rw`, `step-ca-db-snapshots-sync`.
4. TrueNAS: the 13 PVC datasets (matched by exact PV handle), `flash-pool/k8s/controlplane*`, controlplane etcd
   snapshots, and the replicated copies of controlplane/observability/xkc VM zvols under `flash-pool/replication/...`.
5. KVM host `mf-ms-a2-01`: six VMs, six `vmpool/vms/controlplane-*-system` zvols (+81 snapshots each), the xkc-lifecycle
   test zvol, `controlplane-images` pool/ISO, `etcd-snapshot.{service,timer,sh}`, `/etc/controlplane`.
6. Repo: `clusters/controlplane`, controlplane-only apps/overlays, images, workflows, tests, scripts, runbooks.

**Deliberately kept.**
- `zfs-replicate-vms` (host timer): replicates all of `vmpool/vms`, including `pcd-ce`. Never remove it with the cluster.
- NFS shares on the NAS (pcd-ce-nova/-glance, files-esten), the `tf-automation` API key, `nat64-01`, `vmpool/appliances`.
- R2 buckets for core-infra (`etcd-snapshots`, `seaweedfs-db-barman`, `healthchecks-db`) and the shared R2 admin token in
  vault `crossplane-controlplane-secrets`.
- `nas-ula.rye.ninja` /etc/hosts entry and its netplan route on the KVM host (unknown other users).
- Cloudflare token `rackspace-spot-crossplane-controlplane-cluster` (not in scope).

**Gotchas hit.**
- R2 object deletion needs S3 credentials: access key = token ID, secret = SHA-256 hex of the token value. The
  scoped DNS token cannot touch R2; the R2 admin token can.
- The controlplane CSI API key on the NAS had already been deleted; use the Home_Lab `nas.rye.ninja` API key.
- `sudo rm dir/*` on a non-readable directory expands the glob as the unprivileged user; use exact filenames.
- Observability's zvol replicas were still on the NAS after its decommission (cleaned up here).
