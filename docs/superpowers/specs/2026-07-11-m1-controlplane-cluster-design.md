# M1 Design: `controlplane` Cluster on Home Lab KVM (IPv6-only Talos)

Date: 2026-07-11
Status: Approved design, ready for implementation
Parent: [fable-5-arch-plan.md](fable-5-arch-plan.md) milestone M1, [fable-5-arch-spec.md](fable-5-arch-spec.md)
Executor: Sonnet 4.6 under human review

## 1. Goal

Build the new fleet control plane cluster — `controlplane`, trust domain
`controlplane.rye.ninja` — as an IPv6-only Talos Linux cluster on the
`mf-ms-a2-01` KVM host, Flux-syncing `clusters/controlplane/` from a new
rendered repository, with TrueNAS-backed StorageClasses, UniFi BGP
load-balancer VIPs, and a NAT64/DNS64 appliance providing reachability to
IPv4-only endpoints (GitHub, ghcr.io). The cluster ends M1 empty of control
plane services (those migrate in M2) and can be torn down and rebuilt freely.

## 2. Decisions locked in this design

| Decision | Value |
|---|---|
| IP strategy | **IPv6-only** cluster; static ULA for node identity/etcd/internal VIPs; GUA via SLAAC for v6 internet egress and ingress VIPs; **NAT64+DNS64 appliance** for IPv4-only destinations (GitHub/ghcr have no AAAA; UniFi 10.5 has no native NAT64) |
| VM storage | **ZFS mirror** `vmpool` on `nvme1n1`+`nvme2n1` (2x 3.6 TB); libvirt pool on zvols; ZFS snapshots + `zfs send` to TrueNAS as VM-disk DR |
| Cluster shape | 3 control plane VMs (4 vCPU / 8 GB) + 3 workers (4 vCPU / 16 GB), over-committed on the single host (user-approved) |
| Apiserver endpoint | Talos built-in shared VIP (layer 2), on ULA — no BGP dependency for bootstrap |
| Talos policy | Pin current stable release in a single tofu variable; upgrades deliberate via runbook |
| BGP | Gateway AS **64512**, cluster AS **64513**; Calico peers with the UniFi gateway over VLAN 100 |
| Naming | Cluster `controlplane`; trust domain `controlplane.rye.ninja`; stable CA alias `ca.rye.ninja` (introduced M2) |
| Rendered repo | **Separate** repo for this cluster (placeholder name `estenrye/flux-platform-rendered-controlplane`; rename before creation if desired) |
| SOPS | New age key scoped to `clusters/controlplane/` via a `.sops.yaml` creation rule; existing repo admin key kept as second recipient for recovery |
| DR | `talosctl etcd snapshot` schedule (crown jewel) + SOPS-encrypted machine secrets + nightly ZFS snapshot/send of VM zvols to TrueNAS |

## 3. Host inventory

| Item | Value |
|---|---|
| Host | `mf-ms-a2-01.usmnblm01.rye.ninja`, Ubuntu 22.04, libvirt configured |
| Access | `qemu+ssh://automation-user@mf-ms-a2-01.usmnblm01.rye.ninja/system`, key in ssh-agent |
| CPU | AMD Ryzen 9 9955HX, 16 cores / 32 threads, AMD-V + nested virt enabled |
| RAM | 64 GB physical (over-provisioning approved; see 7.3) |
| NICs | 2x Intel X710 10GbE SFP+, LACP bond `bond0` (802.3ad, layer2+3) |
| VM bridge | `br0` = native VLAN on `bond0` = **VLAN 100** |
| VM disks | `nvme1n1` + `nvme2n1` (3.6 TB each, unused) → ZFS mirror `vmpool` |
| OS disk | `nvme0n1` (931 GB, LVM root) — untouched |

Single-host reality: control plane node anti-affinity is impossible in M1;
the host is a SPOF (accepted — still better availability history than
Rackspace Spot). Tofu modules take a host list so a second host slots in
later without redesign.

## 4. Network design

### 4.1 VLAN 100 facts (provided)

| Item | Value |
|---|---|
| IPv4 (unused by this cluster) | `10.45.0.0/16`, gateway `10.45.0.1`, DHCP4 disabled |
| IPv6 GUA | `2607:3640:1064:270::/64` via prefix delegation (TFiber, UniFi `Internet 1`); gateway `2607:3640:1064:270::1`, link-local `fe80::ae8b:a9ff:fe6e:13de`; SLAAC + RA |
| WAN static IPv4 | `66.33.11.233` on `Internet 1` (future IPv4 ingress fallback, not used in M1) |
| TrueNAS | VLAN 100, GUA `2607:3640:1064:270::1000/64`, `nas.rye.ninja` AAAA in Cloudflare; TrueNAS Scale 25.10.4 |

**Renumbering caveat**: everything under the delegated GUA prefix can change
if the ISP re-delegates. All GUA values in this design derive from a single
variable (`gua_prefix`, tofu + EnvironmentConfig) so a renumber is a
one-variable change plus re-render; external-dns keeps AAAA records current.
Node identity, etcd, and internal VIPs are on ULA and are immune.

### 4.2 ULA plan (stable internal addressing)

ULA prefix (RFC 4193 randomly generated; regenerate before implementation if
preferred — record the final value in `providers/kvm/network.yaml`):

**`fd97:45c2:b3a1::/48`**

| Allocation | Range | Purpose |
|---|---|---|
| VLAN 100 infra | `fd97:45c2:b3a1:100::/64` | node addresses, apiserver VIP, appliance, internal LB VIPs |
| apiserver VIP | `fd97:45c2:b3a1:100::10` | Talos shared VIP, `api.controlplane.rye.ninja` (internal DNS) |
| CP nodes | `fd97:45c2:b3a1:100::11` – `::13` | static |
| Workers | `fd97:45c2:b3a1:100::21` – `::23` | static |
| NAT64 appliance | `fd97:45c2:b3a1:100::64` | Tayga + DNS64 |
| TrueNAS (reserved) | `fd97:45c2:b3a1:100::1000` | static |
| mf-ms-a2-01.usmnblm01.rye.ninja | `fd97:45c2:b3a1:100::2000` | static |
| Internal LB VIP pool | `fd97:45c2:b3a1:100:ffff::/112` | Calico BGP-advertised, LAN-internal services |
| Pod CIDR | `fd97:45c2:b3a1:1100::/56` | Calico IPv6 pool (/64 per node) |
| Service CIDR | `fd97:45c2:b3a1:2000::/112` | kube service network |
| Ingress GUA VIP pool | `<gua_prefix>:ffff::/112` | BGP-advertised, internet-facing services (renumber-exposed by design) |

Nodes carry: static ULA (primary, `nodeIP`), SLAAC GUA (v6 internet egress),
link-local. No IPv4 anywhere on cluster nodes.

### 4.3 NAT64 + DNS64 appliance

A minimal Debian/Alpine VM (1 vCPU / 1 GB / 10 GB) on the same bridge,
dual-stack **as the single deliberate exception**: ULA `...:100::64` + static
IPv4 `10.45.0.64/16` for its translated traffic toward the gateway.

- **Tayga** (userspace TUN NAT64, packaged in Ubuntu/Debian — `apt install
  tayga`) translating the well-known prefix `64:ff9b::/96` to a private
  dynamic IPv4 pool (`192.168.255.0/24`) on its TUN interface, with an
  iptables MASQUERADE rule from that pool out the VM's `10.45.0.64` address.
  Chosen over Jool: no out-of-tree kernel module to rebuild across kernel
  upgrades, plain package + config file, cloud-init friendly. Trade-off:
  userspace translation is slower than kernel NAT64 — ample for git and OCI
  pulls, which is all that flows through it.
- **DNS64** (unbound or bind9) at `...:100::64`: forwards to upstream
  resolvers, synthesizes AAAA from A records only when no real AAAA exists.
  Talos nodes and cluster CoreDNS use it as their resolver.
- Talos machine configs carry a static route: `64:ff9b::/96 via
  fd97:45c2:b3a1:100::64`.
- Managed by the same tofu stack; rebuildable from config in minutes; its
  outage breaks only IPv4-only egress (GitHub/ghcr pulls) — running workloads
  and v6-native traffic are unaffected. Runbook covers rebuild + a manual
  `git bundle`/image side-load break-glass path.
- Flag for later: if UniFi ships native NAT64, or GitHub ships AAAA records,
  the appliance retires with zero cluster changes (DNS64 resolver moves to
  the gateway or off).

### 4.4 BGP

- UniFi gateway (AS 64512) peers with Calico (AS 64513) over IPv6. Peer
  target on the cluster side is the gateway's VLAN 100 GUA
  (`<gua_prefix>::1`, prefix-variable) — UniFi's FRR-based BGP config is
  uploaded by hand (human step; config file generated by the agent).
- Calico advertises: internal ULA VIP pool + ingress GUA VIP pool. The
  gateway redistributes so other VLANs reach both (ULA stays site-internal;
  UniFi must not announce ULA or the GUA VIP /112 upstream — the generated
  FRR config includes outbound prefix filters, and verification includes
  checking from the WAN side).
- The apiserver VIP is deliberately NOT BGP-advertised (Talos L2 shared VIP)
  so cluster management works even when BGP is down. Reaching it from other
  VLANs requires a gateway static route for `fd97:45c2:b3a1:100::/64` toward
  VLAN 100 — UniFi treats it as on-link only if the gateway carries a ULA
  interface address; simplest is a static route entry (human step, documented).

### 4.5 Inbound access (M1 scope)

LAN/VPN-only this milestone. Internet-facing exposure (`ca.rye.ninja`,
`sso.rye.ninja`) arrives in M2/M3 on GUA VIPs over IPv6 per your preference.
Two facts recorded now for that work: Cloudflare **proxied** DNS can front an
IPv6-only origin for IPv4 clients on plain HTTPS endpoints, but it terminates
TLS — endpoints needing raw mTLS passthrough (OTLP gateway; any step-ca flow
using client certs) must be reached directly over IPv6 or via the WAN static
IPv4 + a future v4 VIP, not through the Cloudflare proxy. Decision deferred
to M5/M6 when the first out-of-LAN consumer exists.

## 5. Storage design

### 5.1 ZFS on the KVM host (human-run, agent-generated script)

```
zpool create -o ashift=12 vmpool mirror nvme1n1 nvme2n1
zfs set compression=lz4 atime=off vmpool
zfs create vmpool/vms          # libvirt pool (zvols per VM)
zfs create vmpool/appliances   # NAT64 etc.
```

- ARC capped at **8 GB** (`zfs_arc_max`) — the host over-commits guest RAM
  (7.3); ARC must not compete.
- libvirt storage pool of type `zfs` targeting `vmpool/vms`; tofu creates a
  zvol per VM disk.

### 5.2 VM-disk DR to TrueNAS

- Nightly `zfs snapshot -r vmpool/vms@nightly-<date>` + incremental
  `zfs send -I | ssh nas zfs recv` to a TrueNAS dataset (or syncoid);
  retention 7 daily / 4 weekly. Agent writes the script + systemd timer;
  human installs the replication SSH key on TrueNAS.
- Perspective: Talos VM disks are cattle — the **restore-critical** set is
  (a) etcd snapshots, (b) SOPS-encrypted machine secrets in git, (c) PVC
  data on TrueNAS itself. ZFS replication is the convenience layer that
  turns "rebuild the cluster" into "roll back the zvols".

### 5.3 etcd snapshots

CronJob (or systemd timer on the host running `talosctl etcd snapshot`
against the ULA VIP) every 6 h, shipped to a TrueNAS NFS export, pruned at
14 days. Moves to Garage in M3. Restore procedure is part of the M1 runbook
set and must be exercised once before M1 closes (see 9).

### 5.4 In-cluster storage: democratic-csi → TrueNAS

- Target `nas.rye.ninja` (AAAA); TrueNAS Scale **25.10.4** uses the current
  JSON-RPC websocket API — verify the `freenas-api-iscsi`/`freenas-api-nfs`
  driver compatibility matrix at implementation time (validation task; ssh
  drivers are the fallback).
- StorageClasses: `truenas-iscsi` (default, RWO) and `truenas-nfs` (RWX).
- iSCSI over IPv6 requires the **`iscsi-tools`** Talos system extension
  (in the image schematic, 6.1) and bracketed-literal handling — prefer the
  DNS name in portal config; verify in the storage chainsaw suite.
- Human prep on TrueNAS: dataset `tank/k8s/controlplane` (iSCSI zvol parent
  + NFS dataset), enable iSCSI + NFS services on VLAN 100, mint an API key
  (first secret encrypted with the new SOPS key).

## 6. Talos design

### 6.1 Image

Talos image factory schematic (exact stable version pinned in
`providers/kvm/versions.yaml` at implementation time):

- `siderolabs/qemu-guest-agent` — VM lifecycle integration
- `siderolabs/iscsi-tools` — required for democratic-csi iSCSI

### 6.2 Machine config highlights (generated by the bootstrap script)

- Static ULA per node + `accept-ra: true` (SLAAC GUA for egress); no DHCP.
- `machine.network.nameservers: [fd97:45c2:b3a1:100::64]` (DNS64).
- Static route `64:ff9b::/96` via the appliance.
- VIP `fd97:45c2:b3a1:100::10` on the control plane node interface
  (Talos shared-VIP feature).
- `cluster.network`: podSubnets `[fd97:45c2:b3a1:1100::/56]`, serviceSubnets
  `[fd97:45c2:b3a1:2000::/112]`; CNI `none` (Calico installed via Flux).
- `service-account-issuer` left default in M1 (WIF issuer work is M4 scope).
- Machine secrets: `talosctl gen secrets` output SOPS-encrypted at
  `clusters/controlplane/secrets/talos-secrets.sops.yaml` (migrates to
  OpenBao in M3).

### 6.3 VM layout

| VM | vCPU | RAM | Disk (zvol) | ULA |
|---|---|---|---|---|
| `controlplane-cp-{1,2,3}` | 4 | 8 GB | 100 GB | `::11`–`::13` |
| `controlplane-wk-{1,2,3}` | 4 | 16 GB | 200 GB | `::21`–`::23` |
| `nat64-01` | 1 | 1 GB | 10 GB | `::64` (+ `10.45.0.64`) |

Totals: 25 vCPU on 32 threads (fine), 73 GB RAM on 64 GB physical —
**over-commit approved**. Mitigations: `cpu mode=host-passthrough`;
virtio-balloon on all guests; KSM enabled on the host
(`ksmtuned`, conservative); ZFS ARC capped (5.1). Talos has no swap, so the
host must never force guests to their full reservation simultaneously —
Grafana host-memory alert lands in M5; until then `virsh dommemstat` spot
checks are in the runbook. If pressure appears early, workers drop to 12 GB
(one tofu variable).

## 7. Repository work

### 7.1 New artifacts

```
providers/kvm/
  README.md
  versions.yaml            # talos version, image schematic id
  network.yaml             # ULA prefix, gua_prefix var, allocations table (4.2)
  hosts.yaml               # mf-ms-a2-01 inventory (3)
  modules/
    talos-vm/              # libvirt zvol + domain from factory image
    nat64-appliance/       # tayga + unbound cloud-init
  controlplane/            # tofu root module for this cluster
.bin/
  create-controlplane-cluster.sh    # tofu apply + talosctl gen/apply/bootstrap
  destroy-controlplane-cluster.sh
  backup-controlplane-etcd.sh
clusters/controlplane/
  catalog.yaml             # System entity; rye.ninja/kubeconfig annotation;
                           # github.com/project-slug -> new rendered repo;
                           # rye.ninja/flux-source-repo: estenrye/flux-platform-src
  kustomization.yaml       # baseline aggregation (7.2)
  secrets/                 # SOPS (new key) talos secrets, truenas api key
docs/runbooks/             # see section 9
tests/controlplane-baseline/   # chainsaw suites (section 8)
```

`.sops.yaml` gains a creation rule: `path_regex: clusters/controlplane/.*`
→ recipients = new `controlplane` age key + existing repo admin key
(recovery). The new private key never enters the repo; it lives with the
other age keys in your keychain.

### 7.2 Baseline applications (all existing ADR-10 layouts, new variants only where needed)

`clusters/controlplane/kustomization.yaml` aggregates: Calico (IPv6-only
install variant + default-deny per ADR-17 + BGPPeer/BGPConfiguration for
4.4), priority-classes, reloader, gateway-api-crds, envoy-gateway,
external-dns (UniFi webhook variant for LAN AAAA records), democratic-csi
(new application), flux + flux-monitoring, prometheus-operator-crds.
Notably absent until M2: crossplane, step-ca, cert-manager stack.

### 7.3 New rendered repo

Create `estenrye/flux-platform-rendered-controlplane` (rename freely before
creation); CI discovery picks the cluster up from `catalog.yaml` annotations
(ADR-8 — `render-discover-clusters.sh` keys on `rye.ninja/flux-source-repo`),
so the only pipeline change is repo creation + deploy key/token, both human
steps. **CI caveat**: GitHub-hosted runners are IPv4-only — they render and
push to GitHub, never into the cluster, so this doesn't matter; but do not
add CI jobs that must reach the IPv6-only cluster directly.

## 8. Execution sequence

Human steps are marked **[H]**; everything else is agent-authored PRs you review.

| # | Step | Verify |
|---|---|---|
| 1 | **[H]** UniFi: enable BGP (AS 64512), upload agent-generated FRR config with prefix filters; static route for `fd97:45c2:b3a1:100::/64` → VLAN 100 | gateway shows BGP idle (no peer yet) |
| 2 | **[H]** TrueNAS: datasets, iSCSI+NFS services, API key, replication SSH key | API reachable at `nas.rye.ninja` |
| 3 | **[H]** KVM host: run agent-generated ZFS + KSM + ARC prep script (5.1) | `zpool status vmpool` mirror ONLINE |
| 4 | SOPS key creation + `.sops.yaml` rule; encrypt TrueNAS API key | sops round-trip |
| 5 | `providers/kvm/` tofu modules + `.bin/` scripts PR | `tofu plan` clean from workstation via ssh |
| 6 | **Provision the Tayga NAT64/DNS64 VM** (`nat64-01`) via the `nat64-appliance` tofu module: Ubuntu cloud image + cloud-init installing `tayga` and `unbound`; tayga.conf maps `64:ff9b::/96` to pool `192.168.255.0/24`; iptables MASQUERADE to `10.45.0.64`; unbound DNS64 module enabled; IPv6 forwarding + RA config on the VM | VM boots; `systemctl status tayga unbound` healthy; `ip addr` shows ULA `::64` + `10.45.0.64` |
| 7 | NAT64/DNS64 verification | from host or a test VM: v6 ping `64:ff9b::140.82.112.3` (github.com via NAT64); DNS64 synthesizes AAAA for `github.com`; `curl -6 https://github.com` succeeds using the DNS64 resolver |
| 8 | `create-controlplane-cluster.sh`: VMs, machine configs, bootstrap | `talosctl health` clean; nodes NotReady (no CNI yet) |
| 9 | **[H]** Create rendered repo + deploy key | CI renders `clusters/controlplane` |
| 10 | Flux Operator bootstrap → baseline reconciles (Calico first; nodes Ready) | all kustomizations Applied |
| 11 | **[H]** Confirm BGP peering established on gateway | routes for both VIP pools visible; ULA/GUA-VIP prefixes NOT visible from WAN |
| 12 | Chainsaw suites + DR drill (below) | all green |
| 13 | Update `docs/memory/` (kubeconfig lookup) + openbrain; ADRs + runbooks merged | — |

## 9. Validation and exit criteria

Chainsaw suites in `tests/controlplane-baseline/`:

1. **network**: pod-to-pod v6 across nodes; egress to a v6-native endpoint;
   egress to `github.com` through NAT64; default-deny enforced (a namespace
   without allows cannot egress — remember post-DNAT targetPort rule).
2. **storage**: PVC bind + expand on `truenas-iscsi`; RWX on `truenas-nfs`;
   data survives pod rescheduling across nodes.
3. **lb**: LoadBalancer service gets ULA VIP, reachable from another VLAN;
   second service gets GUA VIP, reachable from an external v6 vantage.
4. **flux**: baseline kustomizations healthy; kill one and watch it recover.

Exit criteria (M1 done):

- All suites green; `talosctl health` clean.
- DR drill executed once: restore etcd snapshot onto a rebuilt cluster
  (throwaway rebuild via the destroy/create scripts) and verify baseline
  reconvergence; ZFS replication to TrueNAS verified with a test rollback.
- Runbooks merged: KVM host prep/replace; Talos node replace; Talos upgrade;
  NAT64 appliance rebuild + break-glass; etcd snapshot/restore; TrueNAS
  maintenance; GUA prefix renumber procedure.
- ADRs merged: control plane on Talos-on-KVM (supersedes ADR-3 placement);
  on-prem substrate (Talos + democratic-csi + ZFS); UniFi BGP LB; **IPv6-only
  with ULA internal + NAT64** (new since the plan revision).
- `clusters/controlplane/catalog.yaml` discoverable by CI; kubeconfig path
  recorded in the annotation and in `docs/memory/cluster-kubeconfig-lookup.md`.

## 10. Open items / risks specific to this design

| Item | Handling |
|---|---|
| PD renumber of `2607:3640:1064:270::/64` | Single `gua_prefix` variable; renumber runbook; only ingress GUA VIPs + node egress affected (self-heals via SLAAC); consider asking TFiber/UniFi for stable PD hint |
| NAT64 appliance SPOF | Only breaks v4-only egress; rebuild-from-config runbook; revisit if UniFi adds NAT64 or GitHub adds AAAA |
| democratic-csi vs TrueNAS 25.10 API | Validate driver at implementation; ssh-driver fallback; worst case pin TrueNAS or contribute fix |
| Single KVM host | Accepted SPOF; tofu host-list ready for a second host; ZFS+etcd DR bounds blast radius |
| RAM over-commit (73/64 GB) | Balloon + KSM + ARC cap; workers drop to 12 GB via one variable if pressure appears |
| UniFi BGP config is manual upload | Config file lives in git (`providers/kvm/unifi-frr.conf`); runbook step; drift check in the network suite |
| `Internet 2` (AT&T) has no working IPv6 | Out of scope for M1; Route64 wireguard tunnel noted as an option if `Internet 1` fails and v6 ingress must survive |
