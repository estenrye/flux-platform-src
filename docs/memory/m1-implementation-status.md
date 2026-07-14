---
name: m1-implementation-status
description: Where M1 (controlplane cluster on KVM) implementation stands and what remains
metadata:
  type: project
---

M1 implementation started 2026-07-11 on branch `m1-controlplane-cluster`
(design: docs/superpowers/specs/2026-07-11-m1-controlplane-cluster-design.md).

Done (infrastructure layer, execution steps 1–8 artifacts): `providers/kvm/`
(data files, unifi-frr.conf, host prep + DR scripts, tofu modules talos-vm /
nat64-appliance / controlplane root), `.bin/create|destroy-controlplane-cluster.sh`,
`.bin/backup-controlplane-etcd.sh`, `clusters/controlplane/` scaffolding
(catalog.yaml, .sops.yaml, gitignored age key), six runbooks.

Pinned: Talos v1.13.5 / K8s 1.36.2; schematic id
`6ebbfe35c8225645c05d4d19eaad385bd1ec795954932d0ada671388272fec19`
(qemu-guest-agent + iscsi-tools); libvirt provider `~> 0.8.0` — 0.9.x is an
incompatible plugin-framework rewrite, do not bump casually.

Baseline applications done (2026-07-11): applications/calico/controlplane
(tigera-operator v3.32.1, native LB IPAM, BGP; the chart's pre-delete hook Job
is deleted from the render — applying it would uninstall Calico),
truenas-csi/base (official TrueNAS CSI v1.1.1, JSON-RPC native, digest-pinned; replaced democratic-csi at Esten's request),
external-dns/unifi/base (webhook v0.8.2), default-deny controlplane variant,
clusters/controlplane/kustomization.yaml, .bin/bootstrap-controlplane-flux-key.sh.
All digest-pinned; kube-linter + checkov clean.

TrueNAS reality (differs from design doc): pool is `flash-pool`, not `tank` —
datasets flash-pool/k8s/controlplane, flash-pool/k8s/controlplane-etcd-snapshots,
flash-pool/replication/mf-ms-a2-01.usmnblm01.rye.ninja/vms.

TrueNAS side complete (2026-07-12): iSCSI portal on the static ULA
fd97:45c2:b3a1:100::1000 (portal+initiator group 1, no CHAP), NFS v4,
etcd-snapshot NFS export (restricted to host ULA ::2000), API key encrypted
into clusters/controlplane/resources/truenas-csi.api-credentials.sops.yaml
(1Password: op://controlplane/truenas-api-key), replication user verified
(remote zfs needs /usr/sbin/zfs — non-root SSH PATH lacks /usr/sbin).
Storage data paths use the NAS ULA; API uses wss://nas.rye.ninja.

Also done: tests/controlplane-baseline/ (network/storage/lb/flux suites +
.bin/run-controlplane-baseline.sh), ADRs 0020-0023, truenas-maintenance
runbook.

CLUSTER LIVE + M1 NEARLY DONE (2026-07-13): 6-node cluster bootstrapped,
all 4 baseline suites PASS, Flux reconciling. Storage: truenas-nfs is DEFAULT
(works); truenas-iscsi BLOCKED on IPv6 by upstream csi-lib-iscsi
([[talos-iscsi-truenas-csi]], issues #94 + truenas-csi#45). BGP fully up
(bird6 mesh + gateway peer Established; query bird6 not bird for v6-only).

NAT64 SPLIT (2026-07-13, Esten's call): NAT64 is its own tofu root module
(providers/kvm/nat64, own dir pool nat64-images) with .bin/create-nat64.sh /
destroy-nat64.sh, independent of the cluster lifecycle. Reason: cluster
teardown was destroying the appliance, which cut the workstation's own path
to the IPv4-only Talos factory and blocked rebuild. create-controlplane
prechecks NAT64 and refuses without it.

DR DRILL PASSED (2026-07-13): full teardown + rebuild with RECOVER_FROM=<snap>
(new env in create script → talosctl bootstrap --recover-from). Proven by a
snapshot-only dr-marker ConfigMap surviving the rebuild (not git
reconvergence); 6/6 Ready + all suites green after. Runbook:
docs/runbooks/etcd-snapshot-restore.md.

Known: zvol udev race on tofu apply ("Storage volume not found") — create
script now retries 3x. Workstation on VLAN 100 needs a direct 64:ff9b::/96
route (gateway hairpin dropped as asymmetric) and can't self-test cross-VLAN
LB reachability (VIP on-link in its /64) — lb suite asserts in-cluster
datapath instead.

M1 EXIT CRITERIA CLOSED (2026-07-13 evening): PR #65 merged (+ follow-ups
#66-#70). DR timers verified installed + enabled on the host (etcd snapshots
running 6-hourly, succeeding). Gateway VIP routes CONFIRMED via
`ssh root@fd97:45c2:b3a1:100::1` (jump through the KVM host; 10.45.0.1 is
NOT reachable from the workstation VLAN): both /112 pools in FIB, ECMP
across all 6 nodes, only Calico dynamic neighbors, PfxSnt 0 (DENY-ALL-OUT
verified). ZFS replication live: first run failed — `send -R` of the parent
fs makes remote `recv -F` unmount the mounted target, and Linux ZFS can't
delegate mount/umount to non-root; fixed by per-zvol sends (PR #72,
runbook updated). All 6 zvol snapshot GUIDs match source↔NAS. Rollback
verified by pulling a zvol back from the NAS and sha256-comparing against
the source snapshot ([[truenas-api-surface]] for why the API couldn't fix
the mount issue). Esten added `send` to the replication user's delegation
2026-07-13 — the restore path needs it and the original setup missed it.

Still M1-adjacent, not blocking: truenas-iscsi blocked upstream
([[talos-iscsi-truenas-csi]]); lb suite asserts in-cluster datapath only.

Open decision flagged to Esten: whether to add a repo-admin age key as second
SOPS recipient for `clusters/controlplane/` — the crossplane cluster key is
unsuitable because its private half is tracked in the repo
([[cluster-kubeconfig-lookup]]).

UniFi credentials done (2026-07-12): external-dns secret encrypted
(op://controlplane/unifi-os-external-dns; host = gateway ULA
https://[fd97:45c2:b3a1:100::1] — the gateway DOES carry the VLAN 100 ULA
::1 and serves /proxy/network/integration/v1/* on it). UniFi 10.5 EA UI:
API keys live behind the PLUG ICON in the Network app's left rail
("Integrations"), NOT Settings > Control Plane; creating keys requires
OS-level super admin — Network "Full Management" role still gets Access
Prohibited. Workstation has NO global IPv6 (v4-only VLAN) — never probe
v6 reachability from it; use the KVM host as the VLAN 100 vantage.
