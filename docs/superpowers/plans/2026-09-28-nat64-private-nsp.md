# NAT64 Private-NSP Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second, independent Tayga instance to the `nat64-01` appliance, using a Network-Specific Prefix instead of the RFC 6052 well-known prefix, so the cluster can reach `pcd.rye.ninja` (`10.45.45.45`, a private OpenStack Keystone endpoint) — which the existing well-known-prefix path cannot, by RFC 6052 design.

**Architecture:** `modules/nat64-appliance/templates/user-data.yaml.tftpl` gains a second Tayga config (`/etc/tayga-priv.conf`), its own native systemd unit (`tayga-priv.service`, not a sysv-init-script copy — see Global Constraints), one more NAT44 masquerade rule, and one Unbound `local-data` override for `pcd.rye.ninja`. The existing well-known-prefix instance, its unit, and its rule are untouched. `network.yaml` gains two documentation-only allocation lines (the new values are literals in the template, not wired through `variables.tf`/`main.tf`, matching the existing WKP/pool's own treatment).

**Tech Stack:** OpenTofu (`providers/kvm/nat64`, `providers/kvm/modules/nat64-appliance`), cloud-init (`#cloud-config` templated via `templatefile()`), Tayga (userspace NAT64), Unbound (DNS64 + `local-data`), nftables, systemd.

**Spec:** [docs/superpowers/specs/2026-09-28-nat64-private-nsp-design.md](../specs/2026-09-28-nat64-private-nsp-design.md)

## Global Constraints

- Chosen NSP: `fd97:45c2:b3a1:64:65::/96` (a `/96` inside the appliance's own already-routed `fd97:45c2:b3a1:64::/64` — saves a second `/64` allocation, but a manual static route + UniFi Policy Table rule on the site gateway were in fact still required to make the `/96` reachable from off-VLAN; see the spec §3.2 and the runbook, not "no new route needed anywhere" as originally stated here). `10.45.45.45` embeds as `fd97:45c2:b3a1:64:65::a2d:2d2d`.
- New pool: `192.168.254.0/24` (distinct from the existing `192.168.255.0/24`, so the two instances' NAT rules never collide).
- New instance's own addresses, mirroring the existing `.1`(self)/`.2`(tun) convention confirmed correct in the spec §1: self `192.168.254.1` / `fd97:45c2:b3a1:64:66::1`; tun `192.168.254.2` / `fd97:45c2:b3a1:64:66::2` (a different `/96` sub-block than the `:65::/96` prefix itself — Tayga rejects a self-address that overlaps its own prefix).
- **Do not copy `/etc/init.d/tayga`.** Verified live on `nat64-01`: that script's `TUN_DEVICE`/`IPV6_PREFIX`/`DYNAMIC_POOL` are extracted with `sed` against the hardcoded path `/etc/tayga.conf`, not `/etc/$NAME.conf`. A renamed copy (`NAME=tayga-priv`) would still read the *original* WKP config for those three values, misconfiguring the second instance to manage the first instance's tun device. Use a native systemd unit instead (Task 2) — verified via `tayga.8`'s actual flags (`-c`/`--config`, `-p`/`--pidfile`) — which needs no init-script copy at all.
- Give the new instance its own `data-dir` (`/var/spool/tayga-priv`), distinct from the existing `/var/spool/tayga`, so the two instances' persistent mapping-table files never collide.
- No changes to `variables.tf`, `main.tf`, `nat64/main.tf`, or any file outside `providers/kvm/` (per the spec §4 — the new prefix/pool are literals in the template, reusing the existing `tayga_ula_prefix` template variable for the site ULA base rather than re-hardcoding it).
- The existing well-known-prefix instance (`tayga.service`, tun device `nat64`, pool `192.168.255.0/24`), its nftables rule, and its systemd drop-in are never edited by any task in this plan.
- `nat64-01` is a real, currently-running shared appliance (egress path for this workstation and the `controlplane` cluster). Applying this plan's change replaces the VM (cloud-init `user_data` changes force a `libvirt_cloudinit_disk`/domain replacement) — brief downtime, cattle by design, but **Task 3's actual apply step is a live-infrastructure action requiring explicit confirmation before running**, regardless of which execution mode runs this plan.
- Verify HCL/template correctness with `tofu validate` and `tofu plan` (Task 2) **before** any real apply (Task 3) — each real apply is several minutes (image download/convert already cached, but VM boot + cloud-init + package install), so catching a templating mistake before that cycle matters.
- Commands run from the repo root unless stated otherwise. `tofu`/`yq` are already on `PATH` via `.venv/bin` per `.bin/create-nat64.sh`'s own `PATH` export — source that pattern (`export PATH="$(pwd)/.venv/bin:${PATH}"`) if running `tofu`/`yq` directly outside the scripts.

## Review Focus

1. **A restart or crash of `tayga-priv.service` after an unclean stop.** The tun device and its addresses/routes are set up in `ExecStartPre` (`--mktun`, `ip addr add`, `ip route add`) and torn down in `ExecStartPost`/`ExecStop` — if the teardown didn't run (crash, `kill -9`), a plain restart's `ExecStartPre` re-running `--mktun`/`ip addr add`/`ip route add` on an already-existing device/address/route fails outright unless those lines tolerate "already exists". A reasonable operator restarting a wedged service expects it to come back, not to need a manual `ip link del nat64priv` first.
2. **The existing WKP instance still working after this change.** Every file this plan touches (`user-data.yaml.tftpl`, `nftables.conf`, `dns64.conf`'s sibling drop-ins) is shared infrastructure for both instances; a mistake in the new blocks (e.g. a YAML indentation error in `write_files`) could break the whole cloud-init render, taking down the existing public-egress path too.
3. **`pcd.rye.ninja`'s `local-data` override colliding with real DNS64 synthesis for the same name.** If `dns64-synthall`/the existing `dns64-prefix` block in `dns64.conf` were ever reordered relative to the new `local-data` line, or if Unbound treats `local-data` and the dns64 module inconsistently, a query for `pcd.rye.ninja` could resolve to the wrong prefix. Confirmed via the actual Unbound behavior (Task 3's `dig` step), not assumed from documentation alone.
4. **A stale `pcd.rye.ninja` IPv4 address.** The spec accepts this as a known trade-off (silent wrong answers, not an error) — this plan does not add detection, but the runbook update (Task 4) must say so explicitly, so a future operator debugging "CCM can't reach Keystone" checks this file, not just DNS64/routing again.
5. **The masquerade rule missing its interface/table scoping.** `nftables.conf`'s existing rule scopes to `oifname "lan"`; if the new rule for `192.168.254.0/24` is added to a different chain or without that same scoping, translated private-range traffic could either fail to get masqueraded (never reaching PCD with a routable source) or over-broadly masquerade traffic it shouldn't.

---

## Task 1: Document the new allocation in `network.yaml`

**Files:**
- Modify: `providers/kvm/network.yaml`

**Interfaces:**
- Consumes: nothing (documentation only).
- Produces: nothing later tasks read from this file — the values are literals in Task 2's template edit, not sourced from here. This task exists purely to keep `network.yaml`'s "authoritative record" accurate, matching how the existing `nat64_appliance.nat64_prefix`/`tayga_pool` lines document values that (for the *existing* instance) also happen to be wired through `variables.tf`; for the *new* instance these two new lines are record-only.

- [ ] **Step 1: Confirm the current block (RED — nothing new present yet)**

Run: `grep -n "tayga_priv_pool\|nat64_priv_prefix" providers/kvm/network.yaml`
Expected: no output (the lines don't exist yet).

- [ ] **Step 2: Add the two lines**

In `providers/kvm/network.yaml`, the `allocations.nat64_appliance` block currently reads:

```yaml
  nat64_appliance:
    ula: fd97:45c2:b3a1:64::64
    ipv4: 10.64.64.64/24 # translated-traffic egress toward the v4 gateway, now on its own dedicated VLAN
    tayga_pool: 192.168.255.0/24 # private dynamic pool on the tayga TUN interface
    nat64_prefix: 64:ff9b::/96 # RFC 6052 well-known prefix
```

Change it to:

```yaml
  nat64_appliance:
    ula: fd97:45c2:b3a1:64::64
    ipv4: 10.64.64.64/24 # translated-traffic egress toward the v4 gateway, now on its own dedicated VLAN
    tayga_pool: 192.168.255.0/24 # private dynamic pool on the tayga TUN interface
    nat64_prefix: 64:ff9b::/96 # RFC 6052 well-known prefix, public IPv4 destinations only
    tayga_priv_pool: 192.168.254.0/24 # private dynamic pool for the NSP (private-destination) tayga instance
    nat64_priv_prefix: fd97:45c2:b3a1:64:65::/96 # NSP, carved from this appliance's own /64; private (RFC1918) destinations only -- see docs/superpowers/specs/2026-09-28-nat64-private-nsp-design.md
```

- [ ] **Step 3: Confirm the lines are present and the file is still valid YAML (GREEN)**

Run: `grep -n "tayga_priv_pool\|nat64_priv_prefix" providers/kvm/network.yaml && yq -e '.allocations.nat64_appliance.nat64_priv_prefix' providers/kvm/network.yaml`
Expected: both lines print, and the `yq` query prints `fd97:45c2:b3a1:64:65::/96` (not an error).

- [ ] **Step 4: Commit**

```bash
git add providers/kvm/network.yaml
git commit -m "$(cat <<'EOF'
docs: record the private-NSP NAT64 allocation in network.yaml

Documentation only -- these two values are literals in the cloud-init
template (next commit), not wired through variables.tf/main.tf, matching
how the well-known-prefix instance's own values are already treated for
anything beyond nat64_prefix/tayga_pool_cidr.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add the second Tayga instance, its systemd unit, the NAT44 rule, and the DNS64 override

**Files:**
- Modify: `providers/kvm/modules/nat64-appliance/templates/user-data.yaml.tftpl`

**Interfaces:**
- Consumes: the existing template variable `tayga_ula_prefix` (already passed in from `nat64/main.tf` as `"fd97:45c2:b3a1:64"`) — reused for the new prefix's base (`${tayga_ula_prefix}:65::...`) instead of re-hardcoding the site ULA.
- Produces: nothing later Terraform code reads — this task's output is the rendered cloud-init `user_data` itself, verified by `tofu plan`'s diff in Step 4 and by the live appliance in Task 3.

- [ ] **Step 1: Confirm none of the new content exists yet (RED)**

Run: `grep -n "tayga-priv\|nat64priv\|pcd.rye.ninja\|192.168.254" providers/kvm/modules/nat64-appliance/templates/user-data.yaml.tftpl`
Expected: no output.

- [ ] **Step 2: Add the new `write_files` entries**

In `providers/kvm/modules/nat64-appliance/templates/user-data.yaml.tftpl`, insert four new `write_files` entries immediately after the existing `/etc/systemd/system/tayga.service.d/mtu.conf` entry (i.e., between that entry and the existing `/etc/unbound/unbound.conf.d/dns64.conf` entry):

```yaml
  - path: /etc/tayga-priv.conf
    content: |
      # Userspace NAT64 (RFC 6146), PRIVATE instance: translates a
      # Network-Specific Prefix (not the well-known prefix) so this
      # appliance can also reach RFC 1918 destinations, which the
      # well-known-prefix instance (tayga.service) cannot -- RFC 6052
      # section 3.1 forbids embedding a non-global IPv4 address in the
      # well-known prefix, and tayga enforces it.
      # See docs/superpowers/specs/2026-09-28-nat64-private-nsp-design.md.
      tun-device nat64priv
      # tayga's own addresses inside this translator (distinct from the
      # public instance's pool and from the tun interface's own address
      # below -- same self/tun split as the public instance, see that
      # spec's Section 1 for why they're meant to differ):
      ipv4-addr 192.168.254.1
      ipv6-addr ${tayga_ula_prefix}:66::1
      prefix ${tayga_ula_prefix}:65::/96
      dynamic-pool 192.168.254.0/24
      data-dir /var/spool/tayga-priv

  - path: /etc/systemd/system/tayga-priv.service
    content: |
      # Native unit, not a copy of the packaged /etc/init.d/tayga: that
      # script's TUN_DEVICE/IPV6_PREFIX/DYNAMIC_POOL are extracted from
      # the hardcoded path /etc/tayga.conf (not /etc/$NAME.conf), so a
      # renamed copy would misconfigure this instance against the
      # PUBLIC instance's tun device. See tayga(8) for -c/--config and
      # -p/--pidfile.
      [Unit]
      Description=Userspace NAT64, private NSP instance (nat64priv)
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=forking
      PIDFile=/run/tayga-priv.pid
      ExecStartPre=-/usr/sbin/tayga -c /etc/tayga-priv.conf --mktun
      ExecStartPre=-/sbin/ip link set nat64priv up
      # Clamp to the IPv6 minimum MTU, same reasoning as the public
      # instance's mtu.conf drop-in: PMTUD does not complete across the
      # NAT64 boundary and large TLS records blackhole otherwise.
      ExecStartPre=-/sbin/ip link set dev nat64priv mtu 1280
      ExecStartPre=-/sbin/ip addr add 192.168.254.2 dev nat64priv
      ExecStartPre=-/sbin/ip addr add ${tayga_ula_prefix}:66::2 dev nat64priv
      ExecStartPre=-/sbin/ip route add 192.168.254.0/24 dev nat64priv
      ExecStartPre=-/sbin/ip route add ${tayga_ula_prefix}:65::/96 dev nat64priv
      ExecStart=/usr/sbin/tayga -c /etc/tayga-priv.conf --pidfile /run/tayga-priv.pid
      ExecStopPost=-/sbin/ip link set nat64priv down
      ExecStopPost=-/usr/sbin/tayga -c /etc/tayga-priv.conf --rmtun
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target

  - path: /etc/unbound/unbound.conf.d/pcd-private.conf
    content: |
      # Targeted override, not a second Unbound instance: dns64-prefix is
      # global to the instance and stays the well-known prefix (for
      # github.com/ghcr.io, unbound.conf.d/dns64.conf). This one name
      # bypasses DNS64 synthesis entirely and points straight at its
      # NSP-embedded address. Scoped to this one host on purpose -- a
      # second private hostname is one more local-data line here, not a
      # new mechanism. STALE IF pcd.rye.ninja's IPv4 EVER CHANGES: this is
      # a manually maintained value, not derived from anything (spec
      # 2026-09-28-nat64-private-nsp-design.md, "Operational notes").
      local-data: "pcd.rye.ninja. AAAA ${tayga_ula_prefix}:65::a2d:2d2d"
```

Note: `-/usr/sbin/tayga ...` and `-/sbin/ip ...` (leading `-`) tell systemd to
ignore a non-zero exit from that `ExecStartPre`/`ExecStopPost` line — needed
because a restart after an unclean stop could find the tun device, address,
or route already present (Review Focus item 1); without the `-`, that
`ExecStartPre` failing would abort the whole start.

- [ ] **Step 3: Add the NAT44 rule and enable the new unit**

In the same file, the existing `/etc/nftables.conf` entry's `postrouting`
chain currently reads:

```
      table ip nat {
        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          ip saddr ${tayga_pool_cidr} oifname "lan" masquerade
        }
      }
```

Add a second `ip saddr` line for the new pool, right after the existing one
(same chain, same `oifname` scoping — Review Focus item 5):

```
      table ip nat {
        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          ip saddr ${tayga_pool_cidr} oifname "lan" masquerade
          ip saddr 192.168.254.0/24 oifname "lan" masquerade
        }
      }
```

Then, in the `runcmd` section at the end of the file, change:

```yaml
runcmd:
  - sysctl --system
  - systemctl enable --now qemu-guest-agent nftables
  - systemctl restart nftables
  - systemctl enable --now tayga unbound
  - systemctl restart tayga unbound
```

to:

```yaml
runcmd:
  - sysctl --system
  - mkdir -p /var/spool/tayga-priv
  - systemctl enable --now qemu-guest-agent nftables
  - systemctl restart nftables
  - systemctl daemon-reload
  - systemctl enable --now tayga unbound tayga-priv
  - systemctl restart tayga unbound tayga-priv
```

(`daemon-reload` because `tayga-priv.service` is a hand-written unit file
systemd hasn't seen before, unlike `tayga.service`, which the sysv generator
already produces at boot from the packaged init script; `mkdir -p
/var/spool/tayga-priv` because tayga does not create its own `data-dir`.)

- [ ] **Step 4: Confirm the new content is present, and check the render (GREEN)**

Run: `grep -n "tayga-priv\|nat64priv\|pcd.rye.ninja\|192.168.254" providers/kvm/modules/nat64-appliance/templates/user-data.yaml.tftpl | wc -l`
Expected: a non-zero count (all the new lines).

Run (from `providers/kvm/nat64`, after `export PATH="$(cd ../../.. && pwd)/.venv/bin:${PATH}"` if `tofu` isn't already on `PATH`):
```sh
tofu -chdir=providers/kvm/nat64 init -input=false
tofu -chdir=providers/kvm/nat64 validate
```
Expected: `Success! The configuration is valid.`

Run: `tofu -chdir=providers/kvm/nat64 plan -input=false -var "nat64_image_path=$(ls providers/kvm/.cache/*.raw | head -1)"`
Expected: a plan showing `module.nat64.libvirt_cloudinit_disk.seed` and
`module.nat64.libvirt_domain.vm` will be replaced (cloud-init `user_data`
change forces replacement — expected, this is the "cattle rebuild"). Read
the diff's rendered `user_data` carefully: confirm every new block from
Steps 2-3 appears exactly as written, with no YAML indentation breakage in
the surrounding (unchanged) `write_files` entries — this is what Review
Focus item 2 is checking for. Do **not** proceed to `apply` yet.

- [ ] **Step 5: Commit**

```bash
git add providers/kvm/modules/nat64-appliance/templates/user-data.yaml.tftpl
git commit -m "$(cat <<'EOF'
feat: second, NSP-based tayga instance for private-IPv4 destinations

Adds tayga-priv (native systemd unit, not a copy of the packaged
/etc/init.d/tayga -- that script hardcodes /etc/tayga.conf in its
TUN_DEVICE/IPV6_PREFIX/DYNAMIC_POOL extraction, so a renamed copy would
misconfigure this instance against the public instance's tun device),
its own NAT44 rule, and a targeted Unbound local-data override for
pcd.rye.ninja. The existing well-known-prefix instance is untouched.

Verified with `tofu validate` and `tofu plan` (rendered user_data diff
inspected); not yet applied to the live appliance.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Apply to the live appliance and verify

**Files:** none (infrastructure operation only).

**Interfaces:**
- Consumes: Task 1 and Task 2's committed changes.
- Produces: a running `nat64-01` with both tayga instances; nothing later tasks read programmatically.

**This task replaces the live, currently-running `nat64-01` VM** (brief
downtime for both NAT64 paths during the rebuild — cattle, by design, per
`docs/runbooks/nat64-appliance-rebuild.md`). Stop here and get explicit
confirmation to proceed with the actual `apply`/`create-nat64.sh` run
before continuing, regardless of execution mode.

- [ ] **Step 1: Apply**

**A template-only change needs a real rebuild, not a bare re-apply.**
`tofu apply` alone replaces the `libvirt_cloudinit_disk` (new ISO) but only
updates the `libvirt_domain` in place — no reboot — and even a reboot
wouldn't be enough: `instance-id: nat64-01` never changes, so cloud-init's
NoCloud datasource skips re-running `write_files`/`runcmd` for an
instance-id it already provisioned. Force a genuine destroy+recreate first
(the same recipe `docs/runbooks/nat64-appliance-rebuild.md`'s "Rebuild"
section already documents):

```sh
tofu -chdir=providers/kvm/nat64 taint module.nat64.libvirt_domain.vm
tofu -chdir=providers/kvm/nat64 taint module.nat64.libvirt_volume.system
.bin/create-nat64.sh
```

Expected: the plan shows `libvirt_domain.vm` and `libvirt_volume.system`
(not just `libvirt_cloudinit_disk.seed`) as `-/+ destroy and then create
replacement`, and the script's own built-in verification passes
(`success "NAT64 verified: reached an IPv4-only host over IPv6."`) — this
already re-proves the existing public WKP path (Review Focus item 2) as
part of its normal completion check. Confirm with `uptime` over SSH that
the appliance actually rebooted just now, not days ago — a bare `tofu
apply` can report success while the running guest never picks up the new
config at all (found live 2026-09-28: the domain reported "modified" but
the guest's uptime was still 7 days old).

- [ ] **Step 2: Verify the private path directly**

```sh
dig @fd97:45c2:b3a1:64::64 pcd.rye.ninja AAAA +short
```
Expected: `fd97:45c2:b3a1:64:65::a2d:2d2d` — the NSP address, not absent,
not a WKP-style address (Review Focus item 3).

```sh
ssh nat64admin@fd97:45c2:b3a1:64::64 "systemctl status tayga-priv --no-pager; sudo nft list ruleset | grep -A3 postrouting"
```
Expected: `tayga-priv` `active (running)`; the `nft` output shows both
`ip saddr 192.168.255.0/24 oifname "lan" masquerade` and
`ip saddr 192.168.254.0/24 oifname "lan" masquerade`.

- [ ] **Step 3: End-to-end from the cluster**

Create a diagnostic pod on the `controlplane` cluster (`KUBECONFIG` pointed
at it), hostNetwork + `dnsPolicy: Default` so it uses the node's real
resolv.conf, tolerating the `uninitialized` taint so it can schedule at all
— the exact shape used throughout the live investigation this plan
originated from:

```sh
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: net-debug
  namespace: kube-system
spec:
  hostNetwork: true
  dnsPolicy: Default
  tolerations:
    - key: node.cloudprovider.kubernetes.io/uninitialized
      operator: Exists
      effect: NoSchedule
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
  containers:
    - name: net-debug
      image: nicolaka/netshoot:latest
      command: ["sleep", "600"]
EOF
kubectl -n kube-system wait --for=condition=Ready pod/net-debug --timeout=60s
```

```sh
kubectl -n kube-system exec net-debug -- sh -c 'curl -sk -m 8 -o /dev/null -w "HTTP:%{http_code}\n" https://pcd.rye.ninja/keystone/v3'
```
Expected: an HTTP status code (not `HTTP:000`/connection failure). Also
re-run the public-egress regression from the same pod:
```sh
kubectl -n kube-system exec net-debug -- sh -c 'curl -sk -m 8 -o /dev/null -w "HTTP:%{http_code}\n" https://github.com'
```
Expected: `HTTP:200` (Review Focus item 2, confirmed from the cluster side
too, not just the appliance's own build script).

Clean up the diagnostic pod once both checks pass:
```sh
kubectl -n kube-system delete pod net-debug --now
```

- [ ] **Step 4: The actual motivating case**

Retry the `platformController` `CloudControllerManager` live verification
(`docs/runbooks/cloud-controller-manager-verification.md` in that repo,
steps 2 onward): delete and recreate the crash-looping
`openstack-cloud-controller-manager` pods, and confirm they now
successfully initialize against Keystone instead of failing with
`connection refused`.

- [ ] **Step 5: Nothing to commit** — this task is a live operation with no
file changes. Record the outcome (dig/systemctl/nft output, HTTP codes,
CCM pod status) in Task 4's runbook update instead of a commit here.

---

## Task 4: Update the rebuild runbook

**Files:**
- Modify: `docs/runbooks/nat64-appliance-rebuild.md`

**Interfaces:**
- Consumes: Task 3's verification results (the exact commands/output to
  document).
- Produces: nothing later tasks use.

- [ ] **Step 1: Confirm the private path isn't documented yet (RED)**

Run: `grep -n "tayga-priv\|pcd.rye.ninja\|nat64priv" docs/runbooks/nat64-appliance-rebuild.md`
Expected: no output.

- [ ] **Step 2: Add a verification section for the private path**

In `docs/runbooks/nat64-appliance-rebuild.md`, after the existing `## Verify`
section's three commands (`ping -6`/`dig AAAA github.com`/`curl -6`), add:

```markdown
## Verify: private-NSP path (pcd.rye.ninja)

Added 2026-09-28 —
[design](../superpowers/specs/2026-09-28-nat64-private-nsp-design.md),
[ADR-23 amendment](../adr/0023-ipv6-only-cluster-ula-nat64.md). A second,
independent tayga instance (`tayga-priv`, tun device `nat64priv`) reaches
RFC 1918 destinations the well-known-prefix instance above cannot (RFC
6052 forbids it). Currently scoped to one hostname only.

```sh
dig @fd97:45c2:b3a1:64::64 pcd.rye.ninja AAAA +short   # fd97:45c2:b3a1:64:65::a2d:2d2d
curl -6 -skI https://pcd.rye.ninja/keystone/v3 | head -1
```

On the VM: `systemctl status tayga-priv`; `ip addr show nat64priv`.

**If `pcd.rye.ninja`'s IPv4 address ever changes**: this path breaks
silently (wrong answers, not an error — an accepted trade-off, not a bug).
Update the `local-data` line in
`modules/nat64-appliance/templates/user-data.yaml.tftpl`
(`/etc/unbound/unbound.conf.d/pcd-private.conf`) to the new address's
NSP-embedded form and rebuild.
```

- [ ] **Step 3: Confirm the section is present (GREEN)**

Run: `grep -n "tayga-priv\|pcd.rye.ninja\|nat64priv" docs/runbooks/nat64-appliance-rebuild.md`
Expected: the new lines print.

- [ ] **Step 4: Commit**

```bash
git add docs/runbooks/nat64-appliance-rebuild.md
git commit -m "$(cat <<'EOF'
docs: runbook coverage for the private-NSP NAT64 path

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage.**
- Second tayga instance, its own prefix/pool/addressing (spec §3.1): Task 2.
- NSP carved from the existing `/64` (spec §3.2): Task 2 (template), Task 1 (documented allocation). (§3.2 was itself corrected post-execution: a manual route/firewall rule was required for off-VLAN reachability, not "no new route" as this plan originally summarized it — see Global Constraints.)
- Unbound targeted override, not a second instance (spec §3.3): Task 2.
- NAT44 rule (spec §3.4): Task 2.
- Files touched exactly as scoped, no `variables.tf`/`main.tf`/other-repo changes (spec §4): Global Constraints, Task 1-2.
- Operational notes — staleness, rebuild, rollback (spec §5): Task 4 (staleness documented in the runbook); rebuild and rollback are inherent to the cattle model and not separately actioned.
- Testing (spec §6): Task 3, verbatim.
- ADR amendment (spec §7): already written and committed in the design phase, before this plan.
- The corrected §1 finding (the `.6401`/`.6402` split is not a bug): reflected in Global Constraints and Task 2's design (the new instance's own `.1`/`.2` split is written the same way, deliberately).

**Placeholder scan.** None — every step names an exact command, file, and expected output.

**Type consistency.** The NSP (`fd97:45c2:b3a1:64:65::/96`), pool (`192.168.254.0/24`), and addresses (`.1`/`.2` on both families) are the same values across Task 1's `network.yaml` lines, Task 2's template content, and Task 3's verification commands.

**Review Focus coverage.** Item 1: Task 2's `-` (ignore-failure) prefixes on `ExecStartPre`/`ExecStopPost`, explained inline. Item 2: Task 2 Step 4's `tofu plan` diff inspection, plus Task 3's explicit github.com regression check from both the appliance's own script and the cluster side. Item 3: Task 3 Step 2's `dig` against the live resolver. Item 4: Task 4's runbook section states the staleness trade-off explicitly. Item 5: Task 2 Step 3's `oifname "lan"` scoping matches the existing rule exactly.
