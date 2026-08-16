# Runbook: KVM Host Maintenance (Graceful Reboot)

Scope: a planned reboot of a KVM host (kernel updates, hardware work) that
needs every guest domain stopped cleanly first and brought back up
afterward, without tearing anything down at the Crossplane/Terraform level.
Encoded as the `kvm-host-maintenance` Ansible role/playbook
(`providers/kvm/ansible/`) so this doesn't stay tribal knowledge from one
incident. First run: `mf-ms-a2-01`, 2026-08-15 (pending kernel updates +
Netdata memory-pressure alerts — see `docs/memory/` for that session's
findings if present).

Not a disaster-recovery procedure — for total loss of a host, use
`docs/runbooks/kvm-host-prep.md`'s host-replacement section and
`docs/runbooks/control-plane-cold-start.md`.

## What this does NOT touch

- Network (UniFi/VLANs), TrueNAS, or any other host — this is a
  single-host reboot, not the full cold-start sequence.
- Crossplane/Terraform state — domains are stopped and started with
  `virsh`, which changes runtime power state only. Nothing is destroyed or
  recreated, so there is nothing for Crossplane to reconcile against
  mid-maintenance (and the `controlplane` cluster, which runs the
  reconciler, is itself one of the things going down — so nothing is
  watching during the window anyway).

## Prerequisites

- Ansible on your machine (`ansible-playbook` — this repo's copy is
  ad hoc, not installed via any provisioning step) and SSH agent access to
  `automation-user` on the target host (libvirt group, passwordless sudo —
  same account `docs/runbooks/kvm-host-prep.md` uses).
- The target host's domain fleet is current in
  `providers/kvm/ansible/inventory/kvm-hosts.yml`. If a domain was
  added/removed/renamed since the inventory was last touched, update it
  first — the lists there are the *desired running set* on restart, not
  just whatever happens to be up when you start.
- A maintenance window: rebooting a host that carries the `controlplane`
  cluster takes the platform's Flux/Crossplane control plane down for the
  duration. Workload clusters (e.g. `observability`) keep running on
  last-synced state; they just won't reconcile new changes until
  `controlplane` is back.
- Your own SOPS age private key available locally (`SOPS_AGE_KEY_FILE` or
  the default `~/.config/sops/age/keys.txt`) if the target host carries
  the `controlplane` cluster — the `openbao` phase decrypts
  `clusters/controlplane/secrets/openbao-unseal.sops.yaml` to unseal
  OpenBao and needs it. No fallback: this is deliberate, same boundary as
  every other SOPS-encrypted secret in this repo. Missing key fails that
  phase loudly rather than silently skipping it.

## What the playbook does

1. **Pre-flight**: triggers `etcd-snapshot.service` synchronously (on top
   of its normal 6-hour timer) if that unit exists on the host — no-op on
   hosts that don't run the `controlplane` cluster.
2. **Shutdown**, in order: legacy/unmanaged domains (autostart disabled
   after, never restarted by this playbook) → workload cluster domains
   (e.g. `observability`) → `controlplane` workers → `controlplane`
   control-plane nodes → NAT64/DNS64 appliance last (nothing on the host
   needs egress once every cluster is down). Each domain shutdown is a
   graceful `virsh shutdown`, polled until `shut off`; already-off domains
   are skipped. Fails loudly if anything is still running right before the
   reboot step.
3. **Reboot**: `ansible.builtin.reboot`, waits for the host to go down and
   come back on SSH.
4. **Verify**: `zpool status vmpool` is `ONLINE`, `virsh pool-list` shows
   `vms` and `appliances` active.
5. **Startup**, reverse order: NAT64 first (egress path) → `controlplane`
   control-plane → `controlplane` workers → workload cluster domains.
   Legacy/unmanaged domains are deliberately never brought back.
6. **OpenBao unseal** (separate play, `connection: local` — kubectl/sops
   from the operator's machine, not the KVM host): OpenBao's Shamir seal
   is per-pod-process, not shared via its `postgresql` storage backend, so
   every `openbao-N` pod boots sealed after this reboot regardless of how
   many replicas existed before. Decrypts
   `clusters/controlplane/secrets/openbao-unseal.sops.yaml`, applies the
   threshold (3 of 5) key shares to `openbao-0`, waits for `openbao-1` to
   be created (StatefulSet `OrderedReady` — it doesn't exist until
   `openbao-0` is `Ready`), unseals it, then the same for `openbao-2`. See
   `docs/runbooks/openbao-unseal.md` for the manual procedure this
   encodes. Only ever unseals — never runs `bao operator init`; that's a
   one-time operator ceremony out of scope here. No-op on any host where
   `kvm_maintenance_openbao_unseal_enabled` isn't set (i.e. any future
   host that doesn't carry `controlplane`).

## Running it

```sh
cd providers/kvm/ansible   # ansible.cfg here sets roles_path + default inventory

# Full run, start to finish:
ansible-playbook playbooks/kvm-host-maintenance.yml --limit mf-ms-a2-01

# Or phase by phase, inspecting state by hand in between:
ansible-playbook playbooks/kvm-host-maintenance.yml --limit mf-ms-a2-01 --tags shutdown
# ... confirm `virsh list --all` looks right, then:
ansible-playbook playbooks/kvm-host-maintenance.yml --limit mf-ms-a2-01 --tags reboot,verify,startup
```

## Post-run verification

- `talosctl health` and `kubectl get nodes` against `controlplane` (and
  any workload cluster on the same host) — all nodes `Ready`.
- Flux resumes reconciling once `controlplane`'s API is reachable again.
- `.bin/run-platform-baseline.sh controlplane` if you want the full
  documented baseline check.
- Netdata: pending-reboot alert clears; memory/swap alerts reflect
  whatever headroom exists post-reboot.

## Known gaps

- The domain lists in `kvm-hosts.yml` are hand-maintained, same tradeoff
  as `providers/kvm/hosts.yaml` and the `platform-kvm-hosts`/
  `platform-kvm-network` `EnvironmentConfig`s — nothing derives them from
  the live fleet automatically.
- Legacy/unmanaged domains (domains not provisioned by this repo's
  Terraform) need a human decision the first time they're encountered —
  the playbook only knows to disable-and-skip domains already listed under
  `kvm_maintenance_legacy_domains`; a new one won't be picked up
  automatically.
