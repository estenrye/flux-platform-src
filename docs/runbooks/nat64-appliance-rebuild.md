# Runbook: NAT64/DNS64 appliance rebuild + break-glass

The `nat64-01` VM (Tayga + unbound, `fd97:45c2:b3a1:64::64`) is fully
declarative cloud-init — never repair it, rebuild it. Its outage breaks ONLY
IPv4-only egress (GitHub/ghcr pulls); running workloads and v6-native traffic
are unaffected (M1 design §4.3).

Moved to its own dedicated VLAN 64 (`br64`) on 2026-09-06 — see
`docs/adr/0023-ipv6-only-cluster-ula-nat64.md`'s amendment and
`docs/superpowers/plans/2026-09-06-migrate-nat64-appliance-to-vlan-64.md`
for why. Was previously `fd97:45c2:b3a1:100::64` on shared VLAN 100.

## Rebuild (minutes)

```sh
tofu -chdir=providers/kvm/nat64 taint module.nat64.libvirt_domain.vm
tofu -chdir=providers/kvm/nat64 taint module.nat64.libvirt_volume.system
.bin/create-nat64.sh   # re-applies and waits for NAT64/DNS64 to verify
```

## Verify

From a host using the appliance as resolver (`fd97:45c2:b3a1:64::64`):

```sh
ping -6 -c1 64:ff9b::8c52:7003               # github.com via NAT64 (140.82.112.3)
dig AAAA github.com @fd97:45c2:b3a1:64::64   # DNS64-synthesized 64:ff9b:: answer
curl -6 -sI https://github.com | head -1     # end-to-end through tayga
```

On the VM (`ssh nat64admin@fd97:45c2:b3a1:64::64`, break-glass key from
tofu var `nat64_authorized_ssh_keys`): `systemctl status tayga unbound`;
`ip addr show lan` shows ULA `::64` + `10.64.64.64`.

## Verify: private-NSP path (pcd.rye.ninja)

Added 2026-09-28 —
[design](../superpowers/specs/2026-09-28-nat64-private-nsp-design.md),
[ADR-23 amendment](../adr/0023-ipv6-only-cluster-ula-nat64.md). A second,
independent tayga instance (`tayga-priv.service`, tun device `nat64priv`)
reaches RFC 1918 destinations the well-known-prefix instance above
structurally cannot (RFC 6052 §3.1 forbids embedding a private address in
the WKP). Currently scoped to one hostname, `pcd.rye.ninja`.

### One-time site-network setup (do this once, outside this repo)

Carving the NSP (`fd97:45c2:b3a1:64:65::/96`) out of the appliance's own
already-routed `/64` does **not** by itself make it reachable from other
VLANs — confirmed live 2026-09-28. `ping`/`curl` to the NSP address from a
different VLAN (the `controlplane` cluster, on its own peering VLAN)
failed with an immediate ICMPv6 "Destination unreachable: Address
unreachable" from *that cluster's own gateway* — an active rejection, not
a timeout, before the packet ever reached the appliance's VLAN. The
confirmed fix, done manually on the UniFi gateway (nothing in this repo
manages it — no Terraform/Crossplane resource for it exists):

1. A static route for `fd97:45c2:b3a1:64:65::/96` via the appliance's own
   address, `fd97:45c2:b3a1:64::64`.
2. A UniFi Policy Table rule with **Destination scope = IP** for that same
   `/96` (not a zone-to-zone rule) — the identical pattern
   `docs/memory/unifi-zone-firewall.md` already documents for the
   well-known prefix (`64:ff9b::/96`) when it was first stood up.

If this appliance is ever rebuilt against a *different* site network (new
VLAN, new `/64`), redo both of these by hand — they are gateway
configuration, not part of the cloud-init template, and this repo
re-creates neither of them on rebuild.

**`ndppd` status: enabled live, never isolated as necessary or
unnecessary.** Before the route/rule above were in place, `ndppd` (NDP
proxying — `net.ipv6.conf.lan.proxy_ndp=1` plus a `static` rule for
`fd97:45c2:b3a1:64:65::/96` on the `lan` interface) was installed and
enabled on the appliance to test the hypothesis that the gateway couldn't
discover `nat64-01` as the next-hop via Neighbor Discovery. Enabling it
alone made no observable difference — but that only rules it out as the
*sole* blocker, since the rejection happened before NDP resolution would
ever be attempted, so the test couldn't have shown a difference either
way. It was left running when the route/rule above were added and
end-to-end verification then succeeded, so **the confirmed-working
configuration includes `ndppd` running**, not the route/rule alone in
isolation. Whether `ndppd` turned out to actually be required (the
gateway needing NDP-proxied resolution to reach `nat64-01` once it
decides to route there) or is simply harmless-and-untested-for-removal is
genuinely unknown. On a future rebuild: try the static route + Policy
Table rule alone first; only add `ndppd` (config above) if that alone
isn't sufficient. If you do have to fall back to `ndppd`, please update
this note with the result — this is the one part of the private-NSP setup
that hasn't been cleanly isolated.

### Checks

```sh
dig @fd97:45c2:b3a1:64::64 pcd.rye.ninja AAAA +short   # fd97:45c2:b3a1:64:65::a2d:2d2d
curl -6 -skI https://pcd.rye.ninja/keystone/v3 | head -1
```

On the VM: `systemctl status tayga-priv`; `ip addr show nat64priv` (tun
address is `fd97:45c2:b3a1:64:66::2` — a different `/96` sub-block than
the `:65::/96` prefix it translates, see the gotchas below); `sudo nft
list ruleset | grep -A3 postrouting` shows both the `192.168.255.0/24`
(public) and `192.168.254.0/24` (private) masquerade lines.

Also re-run the WKP checks above (`ping -6`, `dig AAAA github.com`, `curl
-6 github.com`) as a regression check — both paths share the same
cloud-init template, so a mistake in the private path's `write_files`
blocks can break the public path too.

### Gotchas found rebuilding this path (2026-09-28)

- **A template-only `tofu apply` is not a rebuild.** It replaces the
  `libvirt_cloudinit_disk` and updates `libvirt_domain` in place, with no
  reboot — and a reboot alone still wouldn't be enough, because
  `instance-id: nat64-01` in cloud-init's meta_data never changes, so the
  NoCloud datasource skips re-running `write_files`/`runcmd` for an
  instance-id it has already provisioned. Use the taint-based rebuild in
  the "Rebuild" section above, and confirm with `uptime` over SSH that the
  guest actually rebooted just now, not days ago.
- **tayga rejects a self-address that falls inside its own `prefix` — for
  IPv6 only.** Confirmed live error: `Error: ipv6-addr cannot reside
  within configured prefix ...`. This is unlike the IPv4 side, where
  `ipv4-addr` overlapping `dynamic-pool` is explicitly fine per
  `tayga.conf(5)`, and is exactly what the existing WKP instance does. The
  WKP instance never hit this because its self/tun addresses already live
  in the site's own ULA space, disjoint from `64:ff9b::/96` by
  construction; an NSP carved from the appliance's *own* ULA space doesn't
  get that disjointness for free — it has to be chosen deliberately.
  Fixed in this repo: `tayga-priv`'s self/tun addresses
  (`fd97:45c2:b3a1:64:66::1`/`::2`) live in a different `/96` sub-block
  than the prefix they translate (`fd97:45c2:b3a1:64:65::/96`).
- **The route/firewall gap** — see "One-time site-network setup" above;
  this was the biggest surprise of the rebuild.
- **Intermittent: `unbound` can fail to start on a genuinely fresh
  rebuild.** Seen once, on the first genuinely-fresh rebuild in over three
  weeks (2026-09-28): `/var/lib/unbound/root.key` (the DNSSEC trust
  anchor) didn't exist, even though `dns-root-data` (which ships
  `/usr/share/dns/root.key`) was installed, and this image has no
  `unbound-anchor` binary to regenerate it the usual Debian/Ubuntu way. A
  second fresh rebuild minutes later in the same session did not
  reproduce it — this looks like a package-install timing/race in the
  base cloud image, not a deterministic bug, and is out of scope for this
  plan (nothing here touches package installation or the base image). If
  `systemctl status unbound` shows a failed start after a rebuild, check
  `journalctl -u unbound`; if it's this:
  ```sh
  sudo cp /usr/share/dns/root.key /var/lib/unbound/root.key
  sudo chown unbound:unbound /var/lib/unbound/root.key
  sudo systemctl restart unbound
  ```
  fixes it immediately. This blocks **both** NAT64 paths (unbound is
  shared between them), not just the private one.
- **`pcd.rye.ninja`'s IPv4 address is a manually maintained override**
  (`local-data` in
  `/etc/unbound/unbound.conf.d/pcd-private.conf`, rendered from
  `modules/nat64-appliance/templates/user-data.yaml.tftpl`). If it ever
  changes, this path goes stale silently — wrong answers, not an error.
  Update the `local-data` line to the new address's NSP-embedded form
  (`fd97:45c2:b3a1:64:65::<hex of the new IPv4>`) and rebuild.

### Confirmed end-to-end (2026-09-28)

Once the route/firewall fix above was in place: `pcd.rye.ninja` resolved
and answered HTTP 200 from Keystone, both from the appliance itself and
from a diagnostic pod on the `controlplane` cluster; the existing
well-known-prefix path regression-tested clean throughout (HTTP 200 to
github.com, from both the appliance's own build-script check and from the
cluster); and the actual motivating case — the `CloudControllerManager`
custom resource in the `platformController` repo — successfully
initialized all 6 cluster nodes against the real OpenStack cloud
(`kubectl get nodes` showed a real `providerID` on every node and the
`uninitialized` taint gone).

## Break-glass: appliance down and you need code/images NOW

Manual side-load path (M1 design §4.3):

1. **Git**: `git bundle create repo.bundle --all` on a dual-stack machine,
   copy over IPv6 (scp to any node's workload, or via TrueNAS NFS), fetch
   from the bundle.
2. **Images**: `docker pull` + `docker save` on a dual-stack machine, copy,
   then `ctr -n k8s.io images import` via `talosctl` on the target node — or
   push to a registry that has AAAA records.

## Retirement flag

If UniFi ships native NAT64 or GitHub publishes AAAA records, the appliance
retires with zero cluster changes: move the DNS64 resolver (machine config
`machine.network.nameservers`) to the gateway or drop DNS64 entirely, then
`tofu destroy -target=module.nat64`.
