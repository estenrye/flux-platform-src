---
name: observability-decommission
description: The observability cluster (Talos on KVM, M4 proving ground) was decommissioned 2026-11-11: what existed, what was removed and in what order, and what is deliberately left (OpenBao role, 1Password, FRR lines)
metadata:
  type: project
---

Decommissioned 2026-11-11. By then the cluster was already physically gone (no VMs, disks or ZFS datasets on
`mf-ms-a2-01`; API at `fd97:45c2:b3a1:100::30` unreachable), so the work was removing everything that still declared or
trusted it. Related: [[m4-step-tracker]], [[m4-network-architecture-no-isolation-requirement]],
[[provider-ansible-delete-cleanup-broken]].

## Removed (in this order)
1. **Repo** (flux-platform-src #301): `clusters/observability`, nine observability-only overlays under `applications/`,
   `.bin/generate-observability-pki.sh`; emptied `kvm_maintenance_observability_domains` (the maintenance playbook `virsh
   shutdown`s every listed domain, so the next run would have failed on non-existent VMs). The catalog is gone, so CI no longer
   renders it; controlplane/core-infra renders were unchanged (no render PRs).
2. **VLAN 200** (real infrastructure that outlived the cluster). Order mattered so Crossplane could not re-create anything:
   delete `XNetworkSegment observability-vlan-segment` (its `AnsibleRun` is `deletionPolicy: Orphan`, so the host is untouched)
   -> remove `br200`/`bond0.200` live with `ip link del` and delete `/etc/netplan/60-br200.yaml` (no `netplan apply`) -> delete
   `XUnifiNetwork observability-vlan` (its namespaced `tf.m.upbound.io` Workspace destroys exactly one `unifi_network`;
   UniFi networks went 18 -> 17, diff was only that network) -> orphan-then-delete the leftover cluster-scoped Workspace
   `observability` and its secrets (kubeconfig, talosconfig, tfstate).
3. **GitHub**: closed 102 PRs in `flux-platform-rendered-observability`, removed the `flux@observability` deploy key, archived the repo.
4. **Local**: `~/.kube/homelab/observability.yaml`, `~/.talos/homelab-observability.yaml`, and an untracked
   `clusters/observability/.sops.age-key` (the age **private** key for the cluster's CA key) overwritten and deleted.

## Deliberately left (check before assuming they are gone)
- OpenBao on controlplane has been **down since the 2026-11-05 NAS outage** (`openbao-0` 615 restarts; its CNPG database cannot attach
  volumes because `democratic-csi-iscsi-controller` is crash-looping), so the role/policy below could not be removed. Needs OpenBao
  back first. Also: its snapshot jobs last completed ~5-7 days before this date.
- OpenBao on controlplane: policy `remote-observability-secrets-read` and cert role `remote-observability-eso` (trusts
  `spiffe://obs.rye.ninja/ns/external-secrets-operator/sa/external-secrets`). Removing needs the OpenBao root token.
- ~~1Password vault `observability`~~ **Done 2026-11-11:** `sops-age-key` and `service-account-token` archived (the vault is empty;
  permanently deleting `sops-age-key` from the archive is what makes the CA key unrecoverable), and the service account behind the
  token was revoked in the 1Password web admin (deleting an item does not revoke a token).
- The observability intermediate CA ("ryezone-labs Intermediate CA observability", signed by controlplane-int, maxPathLen=0) stays
  valid until it expires; its private key is only recoverable via the age key above.
- `providers/kvm/unifi-frr.conf` (the UDM's BGP config, applied by hand) still has `network fd97:45c2:b3a1:200::/64` and an
  `INFRA-SUBNETS-OUT` prefix-list entry. Inert now (nothing originates the prefix) but stale; edit with the next FRR change.
- controlplane's Crossplane `kvm-network` EnvironmentConfig still reserves `observability` (nodes 0x30-33); it goes with controlplane.
- README roadmap row "Observability ... Planned" and the generic XRD example claims named `observability`.

## Lessons
- Look for **untracked secrets** in a cluster directory before deleting it (`.sops.age-key` was gitignored but on disk).
- `gh pr list` stops at 30 by default; use `--limit`. An archived repo cannot have PRs closed: close them first.
- Shared bases are rendered by several clusters: the render lint exposed that `external-dns/unifi/base` was used by this cluster too.
- Stale inventory is a latent failure (maintenance playbook), not just clutter.
