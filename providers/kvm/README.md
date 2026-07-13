# providers/kvm — `controlplane` cluster on home lab KVM

IPv6-only Talos Linux cluster on the `mf-ms-a2-01` KVM host. Design:
[M1 design doc](../../docs/superpowers/specs/2026-07-11-m1-controlplane-cluster-design.md).

## Layout

| Path | Purpose |
|---|---|
| [versions.yaml](versions.yaml) | Talos/K8s version pins + image factory schematic (single source of truth) |
| [network.yaml](network.yaml) | ULA plan, GUA prefix variable, BGP ASNs — all addressing derives from here |
| [hosts.yaml](hosts.yaml) | KVM host inventory (list-shaped so a second host slots in later) |
| [unifi-frr.conf](unifi-frr.conf) | FRR BGP config uploaded by hand to the UniFi gateway (drift-checked by tests) |
| [scripts/prep-kvm-host.sh](scripts/prep-kvm-host.sh) | One-time host prep: ZFS mirror `vmpool`, ARC cap, KSM, libvirt pools |
| [scripts/etcd-snapshot.*](scripts/) | 6-hourly etcd snapshot to TrueNAS (systemd timer on the host) |
| [scripts/zfs-replicate-vms.*](scripts/) | Nightly zvol replication to TrueNAS (systemd timer on the host) |
| [modules/talos-vm/](modules/talos-vm/) | zvol + libvirt domain; boots factory ISO only while the disk is empty |
| [modules/nat64-appliance/](modules/nat64-appliance/) | Tayga NAT64 + unbound DNS64 Ubuntu VM (cloud-init) |
| [nat64/](nat64/) | Tofu root module for the NAT64 appliance (own dir pool `nat64-images`) |
| [controlplane/](controlplane/) | Tofu root module for the cluster VMs (own dir pool `controlplane-images`) |

## Two independent lifecycles

The **NAT64 appliance** and the **cluster** are separate tofu root modules
with separate libvirt dir pools, so `tofu destroy` on one never touches the
other. This is deliberate: the appliance is shared, long-lived infra the
IPv6-only cluster depends on to reach the IPv4-only Talos factory. If a
cluster teardown also removed it, the rebuild couldn't pull the installer
(and the workstation would lose its own factory/ghcr path). **Bring NAT64 up
first and leave it; rebuild the cluster underneath it freely.**

```sh
# NAT64 (once; rarely destroyed):
.bin/create-nat64.sh                   # tofu apply + verify it translates
.bin/destroy-nat64.sh                  # only to retire the appliance entirely

# Cluster (cattle):
.bin/create-controlplane-cluster.sh    # prechecks NAT64, then apply + talos bootstrap
.bin/backup-controlplane-etcd.sh       # ad-hoc etcd snapshot (pre-upgrade, DR drill)
.bin/destroy-controlplane-cluster.sh   # teardown; NAT64 + machine secrets survive

# Disaster recovery — rebuild AND restore etcd in one shot:
RECOVER_FROM=./etcd-backups/<snap>.snapshot .bin/create-controlplane-cluster.sh
```

Machine configs are generated from `network.yaml` + SOPS-encrypted secrets in
`clusters/controlplane/secrets/` and applied over the network — they never
pass through tofu, so **tofu state holds no cluster secrets**. State is local
to the workstation and gitignored.

Run cluster tofu directly (e.g. `plan`) with the one var the script provides:

```sh
tofu -chdir=providers/kvm/controlplane plan \
  -var schematic_id=$(yq -o=yaml '.talos.schematic' providers/kvm/versions.yaml \
      | curl -fsS -X POST --data-binary @- https://factory.talos.dev/schematics | jq -r .id)
```

## Design invariants worth knowing before touching anything

- **No IPv4 on cluster nodes.** The NAT64 appliance (`fd97:45c2:b3a1:100::64`)
  is the single dual-stack exception; nodes reach IPv4-only endpoints
  (GitHub, ghcr.io) through DNS64 + `64:ff9b::/96`.
- **ULA is identity, GUA is reachability.** Node addresses, etcd, and the
  apiserver VIP live on ULA and survive ISP renumbering; anything derived
  from `gua_prefix` must stay derived (runbook: gua-prefix-renumber).
- **The apiserver VIP is L2, not BGP** — cluster management works with BGP down.
- **RAM is over-committed** (73/64 GB). ARC stays capped, ballooning stays on;
  if pressure appears, drop `worker_memory_mb` to 12288 (one variable).
- **Fixed MACs are load-bearing**: the bootstrap script computes each node's
  maintenance-mode EUI-64 SLAAC address from its MAC.
