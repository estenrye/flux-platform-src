# Runbook: KVM Host Prep — Ansible Version (`mf-ms-a2-01`)

Scope: an Ansible port of `docs/runbooks/kvm-host-prep.md`'s host-prep
script (`providers/kvm/scripts/prep-kvm-host.sh`), plus the base bond0/br0
networking that predates all of this project's tooling and had never been
captured anywhere as code before this — see "Reverse-engineered, not
hand-designed" below. Encoded as the `kvm-host-prep` Ansible role/playbook
(`providers/kvm/ansible/`), same pattern as `kvm-host-maintenance.md`.

**This does not replace `kvm-host-prep.md`.** The bash script is still the
documented procedure for a *new* host (`EXPECTED_HOST`/`DISKS` need hand
edits per host, and the script's own guard rails — refuse-to-touch-a-
foreign-disk, `EXPECTED_HOST` check — are written for a human running it
once, deliberately). This playbook exists for:

- **Drift detection** on `mf-ms-a2-01`: re-run it (see below) and anything
  that reports `changed` instead of `ok` is real drift from the documented
  setup — worth investigating before it surfaces as an incident.
- **A from-scratch alternative** if a future second host makes hand-editing
  a bash script's constants feel worse than editing `hosts.yaml` +
  `network.yaml` (which this playbook reads directly — see below).
- **Capturing `br0`'s own config as code**, which nothing did before this.

## Reverse-engineered, not hand-designed

Everything in `providers/kvm/ansible/roles/kvm-host-prep/` was derived by
reading the live host on 2026-09-01 (`prep-kvm-host.sh`'s own output,
`/etc/netplan/*.yaml`, `zpool`/`zfs`/`virsh` state, package list, AppArmor
local includes) and confirmed against `providers/kvm/hosts.yaml` +
`network.yaml` + the existing `kvm-host-prep.md`/`prep-kvm-host.sh`. It was
then **verified against the live host**: the rendered netplan config is a
byte-for-byte match of `/etc/netplan/50-cloud-init.yaml` as it existed that
day, and a real `--check --diff` run against `mf-ms-a2-01` came back
`changed=0` (after fixing one cosmetic comment-text mismatch — see the
role's `tasks/zfs.yml`). Rerun that check before trusting this document if
much time has passed:

```sh
cd providers/kvm/ansible
ansible-playbook playbooks/kvm-host-prep.yml --limit mf-ms-a2-01 --check --diff
```

## What's in scope

| Concern | Role task file | Source |
|---|---|---|
| KVM/libvirt/QEMU packages | `tasks/packages.yml` | Observed installed; not previously scripted anywhere |
| ZFS ZFS storage driver + libvirtd restart | `tasks/packages.yml` | `prep-kvm-host.sh` §1 |
| Base bond0 (LACP 802.3ad) + br0 (VLAN 100) netplan | `tasks/network.yml` | `/etc/netplan/50-cloud-init.yaml` — **never captured as code before this** |
| AppArmor local includes for zvol/dir-pool access | `tasks/apparmor.yml` | `prep-kvm-host.sh` §1b |
| ZFS mirror `vmpool` + `vms`/`appliances` datasets + ARC cap | `tasks/zfs.yml` | `prep-kvm-host.sh` §2–3 |
| KSM (conservative profile) | `tasks/ksm.yml` | `prep-kvm-host.sh` §4 |
| libvirt ZFS storage pools (`vms`, `appliances`) | `tasks/libvirt_pools.yml` | `prep-kvm-host.sh` §5 |

`playbooks/kvm-host-prep.yml` loads `providers/kvm/hosts.yaml` and
`network.yaml` directly and derives role vars from them (disks, ZFS pool
name, ARC cap, the ULA address, the infra-subnet route, the TrueNAS `/128`
route) — see the role's `defaults/main.yml` for exactly what's derived vs.
what's an explicit, hand-tracked value (the host's GUA address on `br0`
isn't recorded anywhere in `network.yaml` under `kvm_host`, unlike the
numbered node addresses, so it's a literal in the role defaults with a
comment pointing at this gap).

## Out of scope — observed on the host, deliberately not managed here

- **`br5`, `br61` bridges** (`/etc/netplan/50-cloud-init.yaml`, VLANs 5/61
  on the same `bond0`): pre-date this project, aren't in `network.yaml`,
  and `br61` carries the **host's own default route** (`10.5.0.1`) — this
  is general homelab network, not `controlplane` cluster infrastructure.
  The role's netplan template reproduces them **verbatim** (as literal,
  undifferentiated YAML) purely so applying the template doesn't delete
  them — it does not consider them its own, and won't pick up future
  changes to them automatically. If they're ever changed by hand, this
  role's `kvm_host_prep_extra_bridges_yaml`/`_extra_vlans_yaml` defaults
  need a matching manual update or the next run will revert them.
- **`br200`, `br250test`** (`/etc/netplan/60-br200.yaml`,
  `60-br250test.yaml`): test/staging VLAN bridges, created via
  `providers/kvm/ansible/roles/bridge/` (the role that creates *sibling*
  VLAN bridges — it does not and cannot create `br0` itself, since it
  requires `vlan_id >= 1` and native VLAN 100 already rides untagged on
  `bond0`).
- **`/etc/netplan/60-br0.yaml`**: a **vestigial duplicate** of `br0`'s
  definition in `50-cloud-init.yaml` (identical content, including the
  TrueNAS route — right down to the same odd blank-line Jinja-template
  artifacts, suggesting it was written by some now-lost variant of the
  `bridge` role). Netplan's last-file-wins-per-key merge means this file is
  currently the authoritative one for `br0` (sorts after `50-cloud-init.yaml`),
  though the two are identical today so it's harmless. Not touched by this
  role. Worth deleting by hand at some point to remove the confusion, but
  that's a separate, deliberate cleanup — not bundled into this reverse-
  engineering pass.
- **OpenVSwitch** (`openvswitch-switch`, `ovs-vswitchd`, `ovsdb-server` —
  all installed and running): `ovs-vsctl show` reports **zero configured
  bridges**. Installed and running but entirely unused — `br0`/`br5`/`br61`
  are plain Linux bridges, confirmed via `ip -d link show br0` (standard
  bridge attributes, no OVS datapath). Not managed here.
- **`kcli`** (`python3-kcli` package, `/home/automation-user/.kcli/`,
  `/home/automation-user/kcli-k3s/` — a separate git repo with its own
  `playbook.yml`/`cluster.plan.yaml`, plus `kubeadm-cluster.yaml`,
  `k3s-cluster.yaml`, `.kube/k3s-ipv6.yaml` in the same home directory, and
  a `kcli`-managed dir pool at `/etc/libvirt/storage/kcli.xml` →
  `/var/lib/kcli/images`): unrelated side experimentation with k3s/kubeadm
  clusters via `kcli`, entirely separate from the `controlplane` Talos
  cluster this repo manages. Explains the `provision-k3s` and inactive
  `k3s-ctrl-0N`/`k3s-worker-0N` libvirt pools visible in `virsh pool-list
  --all` — not this project's infrastructure, not touched here.
- **`netdata`, `podman`**: monitoring and container-runtime packages
  present and running on the host, unrelated to KVM/libvirt. Not touched
  here.

## Running it

```sh
cd providers/kvm/ansible   # ansible.cfg here sets roles_path + default inventory

# Check for drift without changing anything:
ansible-playbook playbooks/kvm-host-prep.yml --limit mf-ms-a2-01 --check --diff

# Apply for real (idempotent; see blast-radius note below):
ansible-playbook playbooks/kvm-host-prep.yml --limit mf-ms-a2-01

# Or by phase:
ansible-playbook playbooks/kvm-host-prep.yml --limit mf-ms-a2-01 --tags network
```

Tags: `packages`, `network`, `apparmor`, `zfs`, `ksm`, `libvirt-pools`.

## Blast radius — read before running for real

- **`tasks/network.yml` rewrites `/etc/netplan/50-cloud-init.yaml` and runs
  `netplan apply`.** This file is `br0` (the `controlplane` cluster's only
  network path) **and** `br61` (the host's own default route / SSH access
  path) **and** `br5`. A mistake here can sever your own SSH session to the
  host and/or take the cluster's network down. It was verified byte-exact
  against the live file before being written (see above), but if you've
  changed any of `br0`/`br5`/`br61` by hand since, **diff the rendered
  template against the live file before running `netplan apply` for real**:
  ```sh
  ansible-playbook playbooks/kvm-host-prep.yml --limit mf-ms-a2-01 --check --diff --tags network
  ```
  If that shows a diff you don't expect, stop and reconcile it — don't
  apply blind.
- **`tasks/zfs.yml`'s pool-creation block only runs when `zpool list
  vmpool` fails** (i.e., only on a genuinely fresh host) — on `mf-ms-a2-01`
  today this entire block is skipped. Its disk-safety refusals (partition
  check, `blkid` signature check) mirror `prep-kvm-host.sh` exactly.
- Everything else (packages, AppArmor, KSM, libvirt pool
  define/autostart/start) is safe to re-run — same idempotent design as
  `prep-kvm-host.sh` itself.

## Host replacement

For a second host or a full replacement, see `kvm-host-prep.md`'s
"Host replacement" section — it's unchanged by this playbook's existence.
This playbook does make that scenario slightly easier: add the new host to
`hosts.yaml` + the ansible inventory, override
`kvm_host_prep_bond_members`/`_bond_name`/`_bridge_name` (hardware-specific,
not derived from any YAML source today — see the role's `defaults/main.yml`),
and the ZFS/ARC/libvirt-pool values fall out of `hosts.yaml` automatically.
