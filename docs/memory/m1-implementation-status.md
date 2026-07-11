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
democratic-csi/base (chart 0.15.1, image v1.9.5 digest-pinned),
external-dns/unifi/base (webhook v0.8.2), default-deny controlplane variant,
clusters/controlplane/kustomization.yaml, .bin/bootstrap-controlplane-flux-key.sh.
All digest-pinned; kube-linter + checkov clean.

TrueNAS reality (differs from design doc): pool is `flash-pool`, not `tank` —
datasets flash-pool/k8s/controlplane, flash-pool/k8s/controlplane-etcd-snapshots,
flash-pool/replication/mf-ms-a2-01.usmnblm01.rye.ninja/vms.

Remaining for M1: SOPS secrets (TrueNAS API key -> democratic-csi driver
configs, UniFi API key -> external-dns) + uncomment them in the cluster
kustomization; rendered repo creation BEFORE opening the M1 PR (push-cluster
CI leg needs it); `tests/controlplane-baseline/` chainsaw suites; ADRs
(Talos-on-KVM, on-prem substrate, UniFi BGP LB, IPv6-only+NAT64);
truenas-maintenance runbook; human steps 2–3 finishing (API key, replication
user, host prep); cluster bring-up; DR drill before M1 close. Human step 1
(UniFi BGP) done 2026-07-11.

Open decision flagged to Esten: whether to add a repo-admin age key as second
SOPS recipient for `clusters/controlplane/` — the crossplane cluster key is
unsuitable because its private half is tracked in the repo
([[cluster-kubeconfig-lookup]]).
