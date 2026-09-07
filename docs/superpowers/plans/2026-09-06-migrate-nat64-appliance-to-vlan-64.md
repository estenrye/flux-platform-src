# Migrate the NAT64/DNS64 appliance to its own dedicated VLAN (VLAN 64)

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `nat64-01` (Tayga NAT64 + unbound DNS64, currently
`fd97:45c2:b3a1:100::64`) off VLAN 100 onto its own dedicated tagged VLAN
64, so that VLAN-100-resident clients (the `controlplane` Talos cluster,
and separately a Platform9 PCD hypervisor in a different repo) stop
hitting an asymmetric-routing bug where the UniFi gateway's static route
to the appliance targets a host that's also on-link, triggering ICMPv6
Redirects that break data transfer through the NAT64 path (TCP handshakes
complete, transfer stalls/resets).

**Architecture:** Reuse the `XNetworkSegment`/`XUnifiNetwork` Crossplane
compositions already proven for this exact bug class (the `observability`
cluster's now-torn-down VLAN 200, 2026-08-04/05) instead of hand-rolling
new bridge/netplan logic. `nat64-01`'s own Terraform module gets repointed
to the new bridge and readdressed; the appliance's move is the real
cutover moment (brief downtime). Two dependent consumers of its old
address — the `controlplane` Talos nodes' machine-config route injection,
and a Crossplane composition's hardcoded env var — need code fixes as
part of this, not just an address bump, or they break outright.

**Tech Stack:** OpenTofu/Terraform (`providers/kvm/`), Crossplane
(`XNetworkSegment`, `XUnifiNetwork`), `yq`/bash (`.bin/create-controlplane-cluster.sh`),
Talos (`talosctl`), UniFi Network (manual UI step for the static route).

---

## Key Facts

- **This exact bug already happened once.** `clusters/controlplane/crossplane-resources/crossplane.environment-config.kvm-network.yaml`
  documents a 2026-08-04 outage: `observability`'s static route to a
  subnet nested on VLAN 100's shared bridge caused the identical
  ICMPv6-redirect hairpin, breaking the Talos API's TLS handshake
  outright. The fix — a real dedicated tagged VLAN via `XNetworkSegment` —
  worked, and was only abandoned later for an unrelated reason
  (`observability` didn't need isolation and moved to BGP-based isolation
  instead, `docs/memory/m4-network-architecture-no-isolation-requirement.md`).
  NAT64 doesn't fit that shared-subnet pattern (it's not a BGP-peered
  cluster), so the dedicated-VLAN fix is reused here as-is.
- **Chosen VLAN ID: 64** — confirmed unused anywhere in the repo (`grep -rl "vlanId: 64\b" .` returns nothing outside this plan). Thematically matches the appliance's own `::64` suffix.
- **Allocations:**
  - ULA subnet: `fd97:45c2:b3a1:64::/64` — appliance `fd97:45c2:b3a1:64::64`, gateway (UniFi, auto) `fd97:45c2:b3a1:64::1`
  - IPv4 subnet: `10.64.64.0/24` (only the appliance and the gateway will ever be on this segment — a /24, not VLAN 100's oversized /16) — appliance `10.64.64.64`, gateway (UniFi, auto) `10.64.64.1`
- **The controlplane Talos route-injection bug (the most important catch in this plan):**
  `.bin/create-controlplane-cluster.sh`'s `render_node()` (lines 188-220)
  unconditionally injects `routes: - network: ${NAT64_PREFIX} gateway:
  ${NAT64_ULA}` into all 6 nodes' (`cp-1/2/3`, `wk-1/2/3`) machine
  configs. This only works today because `nat64-01` is on-link with them.
  `images/docker/talos-cluster-bootstrap/bootstrap.sh` (lines 179-202)
  already hit this exact failure once building `observability` and fixed
  it with an on-link conditional — verbatim comment: *"an explicit route
  to it is only installable when it's actually on-link for this node's
  own subnet... the kernel rejects the route outright ('no route to
  host'), and that failure loops forever, which blocks cri/kubelet/etcd
  from ever starting."* `create-controlplane-cluster.sh` needs the
  identical conditional **before** it's re-run post-move (Task 5), or all
  6 controlplane nodes get a route the kernel rejects and the cluster
  goes down.
- **`providers/kvm/hosts.yaml`'s `bridge: br0` is shared** by
  `providers/kvm/nat64/main.tf` and `providers/kvm/controlplane/main.tf`.
  Do **not** repoint it — that would also move controlplane's VMs. Add a
  `bridge:` field to the new `vlan64:` block in `network.yaml` instead.
- **The cloud-init template hardcodes two more VLAN-100 addresses**
  (`fd97:45c2:b3a1:100::6401`/`::6402`, tayga's internal tun-device
  addressing) not derived from `ula_address` — these need a new template
  variable, or tayga's tunnel stays pinned to the old subnet.
- **No `unifi_static_route` Terraform resource exists anywhere in this
  repo.** Static routes are explicitly hand-maintained
  (`providers/kvm/unifi-frr.conf`'s header, `docs/runbooks/control-plane-cold-start.md`).
  Task 6 is a manual UniFi web UI step — do not try to script it.
- **Firewall zone is not expected to be a blocker**: `docs/memory/unifi-zone-firewall.md`
  confirms the `64:ff9b::/96` policy rules are destination-scoped, not
  zone/network-scoped, and `XUnifiNetwork`'s default `firewallZone`
  (`DMZ-Kubernetes`) is the same zone VLAN 100 is already in — worth a
  live check post-cutover regardless (Task 8).

---

## File Map

| File | Action | Description |
|---|---|---|
| `applications/crossplane-resources/xnetworksegment/examples/vlan64-nat64.yaml` | Create | `XNetworkSegment` claim for the new dedicated VLAN 64 bridge |
| `applications/crossplane-resources/xunifinetwork/examples/vlan64-nat64.yaml` | Create | `XUnifiNetwork` claim for VLAN 64's UniFi network object |
| `providers/kvm/network.yaml` | Modify | Add `vlan64:` block; update `allocations.nat64_appliance` addresses |
| `providers/kvm/nat64/main.tf` | Modify | Repoint `bridge`/`ipv4_gateway`/`lan_dns_addr` from `vlan100` to `vlan64` |
| `providers/kvm/modules/nat64-appliance/variables.tf` | Modify | Add `tayga_ula_prefix` variable |
| `providers/kvm/modules/nat64-appliance/main.tf` | Modify | Pass new var into `templatefile()` |
| `providers/kvm/modules/nat64-appliance/templates/user-data.yaml.tftpl` | Modify | Replace two hardcoded `::6401`/`::6402` literals with the new var |
| `.bin/create-controlplane-cluster.sh` | Modify | Add on-link conditional to `render_node()`'s route block |
| `applications/crossplane-resources/xkubernetescluster/composition.yaml` | Modify | Template `NAT64_ULA`/`NAT64_PREFIX` from `$environment` instead of hardcoding |
| `clusters/controlplane/crossplane-resources/crossplane.environment-config.kvm-network.yaml` | Modify | Add top-level `nat64Ula`/`nat64Prefix` fields |
| `docs/runbooks/nat64-appliance-rebuild.md` | Modify | New address throughout; delete the now-obsolete "Client routing quirk" section |
| `docs/adr/0023-ipv6-only-cluster-ula-nat64.md` | Modify | Add a dated amendment noting the move |

---

## Task 1: Create the `XNetworkSegment` claim for VLAN 64

> **DEVIATION (2026-09-06):** the kubeconfig at
> `~/.kube/spot/ryezone-labs/crossplane-controlplane-cluster.yaml` points
> to a stale Rackspace Spot hostname (confirmed NXDOMAIN against both the
> local resolver and 1.1.1.1) — Crossplane is unreachable. The claim file
> was still written (as the hand-synced declarative record, matching
> `vlan100`'s own convention), but the actual bridge was created manually
> instead: a hand-written `/etc/netplan/60-br64.yaml` on `mf-ms-a2-01`
> (dry-run verified via an isolated `--root-dir` first, then applied for
> real — `br64`/`bond0.64` confirmed up, `br0`/SSH confirmed unaffected).
> The UniFi network object was created manually via the web UI by the
> user. **Apply the claim files for real once a working kubeconfig is
> available**, so Crossplane's state catches up to reality.

**Files:**
- Create: `applications/crossplane-resources/xnetworksegment/examples/vlan64-nat64.yaml`

- [x] **Step 1: Create the file**

```yaml
# applications/crossplane-resources/xnetworksegment/examples/vlan64-nat64.yaml
apiVersion: platform.rye.ninja/v1alpha1
kind: XNetworkSegment
metadata:
  name: vlan64-nat64
  labels:
    rye.ninja/component: xnetworksegment
    rye.ninja/owner: platform-engineering
    platform.rye.ninja/network-segment-name: vlan64-nat64
spec:
  vlanId: 64
  # taggedVlan defaults to true, bondInterface defaults to "bond0" -- both
  # omitted deliberately, matching a genuinely new segment (unlike vlan100's
  # adopted br0). bridgeName omitted too -- derives "br64".
  dhcp4: false
  dhcp6: false # ULA + static IPv4 only, same dual-stack-exception shape nat64-01 already has -- no GUA/PD need on this segment.
  addresses: {} # mf-ms-a2-01 itself needs no address here -- only the nat64-01 VM guest (addressed via its own cloud-init) and the UniFi gateway live on this segment.
  routes: {} # Deliberately empty -- see xrd.yaml's own warning: a nested on-link route here is exactly the bug class this migration fixes.
  unifiNetworkRef:
    name: vlan64-nat64
```

- [ ] **Step 2: Verify the claim applies cleanly (blocked — see deviation above; do once kubeconfig is fixed)**

```bash
export KUBECONFIG=~/.kube/spot/ryezone-labs/crossplane-controlplane-cluster.yaml
kubectl apply -f applications/crossplane-resources/xnetworksegment/examples/vlan64-nat64.yaml --dry-run=server
```

Expected: `xnetworksegment.platform.rye.ninja/vlan64-nat64 created (server dry run)`

---

## Task 2: Create the `XUnifiNetwork` claim for VLAN 64

> **DEVIATION (2026-09-06):** same blocker as Task 1 — claim file written,
> not applied. UniFi network object created manually by the user via the
> web UI instead.

**Files:**
- Create: `applications/crossplane-resources/xunifinetwork/examples/vlan64-nat64.yaml`

- [x] **Step 1: Create the file**

```yaml
# applications/crossplane-resources/xunifinetwork/examples/vlan64-nat64.yaml
apiVersion: platform.rye.ninja/v1alpha1
kind: XUnifiNetwork
metadata:
  name: vlan64-nat64
  labels:
    rye.ninja/component: xunifinetwork
    rye.ninja/owner: platform-engineering
    platform.rye.ninja/unifi-network-name: vlan64-nat64
spec:
  vlanId: 64
  infraSubnet: "fd97:45c2:b3a1:64::/64"
  ipv4Subnet: "10.64.64.1/24"
  # firewallZone left at default (DMZ-Kubernetes) -- same zone VLAN 100 is
  # already in, so DMZ-Kubernetes -> DMZ-Kubernetes: Allow All already
  # covers reachability (docs/memory/unifi-zone-firewall.md).
```

- [ ] **Step 2: Verify the claim applies cleanly (blocked — do once kubeconfig is fixed)**

```bash
kubectl apply -f applications/crossplane-resources/xunifinetwork/examples/vlan64-nat64.yaml --dry-run=server
```

- [ ] **Step 3: Apply both claims for real and wait for readiness (blocked — do once kubeconfig is fixed, to bring Crossplane's state in line with the manually-created reality)**

```bash
kubectl apply -f applications/crossplane-resources/xunifinetwork/examples/vlan64-nat64.yaml
kubectl apply -f applications/crossplane-resources/xnetworksegment/examples/vlan64-nat64.yaml
kubectl wait --for=condition=Ready xunifinetwork/vlan64-nat64 --timeout=5m
kubectl wait --for=condition=Ready xnetworksegment/vlan64-nat64 --timeout=5m
```

- [x] **Step 4: Confirm the bridge exists on the KVM host and the network object exists in UniFi**

```bash
ssh mf-ms-a2-01.usmnblm01.rye.ninja "ip link show br64 && ip -6 addr show br64"
```

Confirmed manually: `br64` up with `fd97:45c2:b3a1:64::2000/64`,
`bond0.64@bond0` correctly enslaved (`master br64`), `br0`/SSH unaffected.
UniFi network object confirmed created by the user via the web UI. **Gate
satisfied — proceeding to Task 3.**

---

## Task 3: Update `providers/kvm/network.yaml`

**Files:**
- Modify: `providers/kvm/network.yaml`

- [x] **Step 1: Add the `vlan64:` block and update `nat64_appliance` allocations**

```diff
 vlan100:
   ipv4_subnet: 10.45.0.0/16
   ipv4_gateway: 10.45.0.1
   ipv6_gateway_gua: 2607:3640:1064:270::1
   ipv6_gateway_ula: fd97:45c2:b3a1:100::1
   ipv6_gateway_link_local: fe80::ae8b:a9ff:fe6e:13de

+# Dedicated tagged VLAN for nat64-01 only (migrated off VLAN 100
+# 2026-09-06 to fix an ICMPv6-redirect hairpin bug -- see ADR-23
+# amendment and docs/runbooks/nat64-appliance-rebuild.md). Only the
+# appliance and the UniFi gateway itself are ever on this segment.
+vlan64:
+  bridge: br64 # nat64/main.tf reads this directly -- do NOT read hosts.yaml's shared bridge field for this.
+  ipv4_subnet: 10.64.64.0/24
+  ipv4_gateway: 10.64.64.1
+  ipv6_gateway_ula: fd97:45c2:b3a1:64::1
+
 allocations:
   infra_subnet: fd97:45c2:b3a1:100::/64
   apiserver_vip: fd97:45c2:b3a1:100::10
@@
   nat64_appliance:
-    ula: fd97:45c2:b3a1:100::64
-    ipv4: 10.45.0.64/16 # translated-traffic egress toward the v4 gateway
+    ula: fd97:45c2:b3a1:64::64
+    ipv4: 10.64.64.64/24 # translated-traffic egress toward the v4 gateway, now on its own dedicated VLAN
     tayga_pool: 192.168.255.0/24
     nat64_prefix: 64:ff9b::/96
```

- [x] **Step 2: Verify the YAML is still valid**

```bash
yq -r '.vlan64, .allocations.nat64_appliance' providers/kvm/network.yaml
```

Confirmed (via `yaml.safe_load`): `vlan64: {bridge: br64, ipv4_subnet:
10.64.64.0/24, ipv4_gateway: 10.64.64.1, ipv6_gateway_ula:
fd97:45c2:b3a1:64::1}`; `nat64_appliance: {ula: fd97:45c2:b3a1:64::64,
ipv4: 10.64.64.64/24, ...}`.

---

## Task 4: Update `providers/kvm/nat64/main.tf`

**Files:**
- Modify: `providers/kvm/nat64/main.tf`

- [x] **Step 1: Repoint bridge, IPv4 gateway, and DNS forward address to the new VLAN**

```diff
   base_image_path = var.nat64_image_path
-  bridge          = local.host.bridge
+  bridge          = local.network.vlan64.bridge
   mac             = "52:54:00:b3:a1:64"
   ula_address     = "${local.network.allocations.nat64_appliance.ula}/64"
   ipv4_address    = local.network.allocations.nat64_appliance.ipv4
-  ipv4_gateway    = local.network.vlan100.ipv4_gateway
+  ipv4_gateway    = local.network.vlan64.ipv4_gateway
   tayga_pool_cidr = local.network.allocations.nat64_appliance.tayga_pool
   nat64_prefix    = local.network.allocations.nat64_appliance.nat64_prefix
   dns64_allowed_cidrs = [
     local.network.ula_prefix,
     "fd92:b792:95e:db94::/64",
   ]
   lan_forward_domain = "rye.ninja"
-  lan_dns_addr       = local.network.vlan100.ipv6_gateway_ula
+  lan_dns_addr       = local.network.vlan64.ipv6_gateway_ula
+  tayga_ula_prefix    = "fd97:45c2:b3a1:64"
```

(`tayga_ula_prefix` feeds Task 5's new module variable — see there for why
it's a plain literal rather than derived from `ula_address`, matching this
file's existing convention for single-use appliance values like the `mac`
line above it.)

- [x] **Step 2: Verify the plan is sane**

```bash
tofu -chdir=providers/kvm/nat64 init -upgrade=false
tofu -chdir=providers/kvm/nat64 plan -var "nat64_image_path=<cached raw image>"
```

Confirmed: `Plan: 1 to add, 1 to change, 1 to destroy` — cloud-init disk
replaced (all four addresses correctly updated: `ipv6-addr`,
`IPV6_TUN_ADDR`, DNS64 `interface:`, `forward-addr:`), `libvirt_domain.vm`
updated in place (`network_interface.bridge`: `br0` -> `br64`), output
`nat64_address` updated. Nothing else touched.

---

## Task 5: Update the `nat64-appliance` module (variables + cloud-init template)

**Files:**
- Modify: `providers/kvm/modules/nat64-appliance/variables.tf`
- Modify: `providers/kvm/modules/nat64-appliance/main.tf`
- Modify: `providers/kvm/modules/nat64-appliance/templates/user-data.yaml.tftpl`

- [x] **Step 1: Add the new variable**

```diff
 variable "bridge" {
-  description = "Host bridge carrying VLAN 100"
+  description = "Host bridge carrying this appliance's dedicated VLAN"
   type        = string
 }
+
+variable "tayga_ula_prefix" {
+  description = "ULA /64 prefix (without trailing ::) this appliance's VLAN uses, for tayga's own internal tun-device addresses (::6401/::6402) -- distinct from ula_address, which is the appliance's own primary interface address on the same prefix."
+  type        = string
+}
```

- [x] **Step 2: Pass it into the template**

```diff
   user_data = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
     hostname            = var.name
     mac                 = var.mac
     ula_address         = var.ula_address
     ipv4_address        = var.ipv4_address
     ipv4_gateway        = var.ipv4_gateway
     tayga_pool_cidr     = var.tayga_pool_cidr
     tayga_pool_gw       = local.tayga_pool_gw
+    tayga_ula_prefix    = var.tayga_ula_prefix
     nat64_prefix        = var.nat64_prefix
     dns64_allowed_cidrs = var.dns64_allowed_cidrs
     lan_forward_domain  = var.lan_forward_domain
     lan_dns_addr        = var.lan_dns_addr
     authorized_ssh_keys = var.authorized_ssh_keys
   })
```

- [x] **Step 3: Replace the two hardcoded addresses in the cloud-init template**

```diff
   - path: /etc/tayga.conf
     content: |
       tun-device nat64
       ipv4-addr ${tayga_pool_gw}
-      ipv6-addr fd97:45c2:b3a1:100::6401
+      ipv6-addr ${tayga_ula_prefix}::6401
       prefix ${nat64_prefix}
       dynamic-pool ${tayga_pool_cidr}
       data-dir /var/spool/tayga

   - path: /etc/default/tayga
     content: |
       RUN="yes"
       CONFIGURE_IFACE="yes"
       CONFIGURE_NAT44="no"
       IPV4_TUN_ADDR="192.168.255.2"
-      IPV6_TUN_ADDR="fd97:45c2:b3a1:100::6402"
+      IPV6_TUN_ADDR="${tayga_ula_prefix}::6402"
       DAEMON_OPTS=""
```

- [x] **Step 4: Verify rendered cloud-init looks right (plan already covers this via Task 4 Step 2, but double check the diff)**

```bash
tofu -chdir=providers/kvm/nat64 plan | grep -A3 "6401\|6402"
```

Confirmed: both `ipv6-addr fd97:45c2:b3a1:64::6401` and
`IPV6_TUN_ADDR="fd97:45c2:b3a1:64::6402"` show the new prefix.

---

## Task 6: Cut over `nat64-01` (real downtime window)

> **Note (2026-09-07):** the first `apply` (in-place update: `bridge`
> `br0` -> `br64`) reported success, but the running guest never actually
> picked up the change — `libvirt_domain`'s in-place modification updated
> the XML definition without the live VM re-reading either the new bridge
> attachment or the new cloud-init network config (`cloud-init status:
> done` with an unchanged `instance-id` — cloud-init won't reprocess
> network config for an instance it's already seen). SSH to the *old*
> address afterward showed it fully still on the old network (old
> addresses, old default route) — which is also why the script's own
> "NAT64 verified" check passed prematurely (it verified the still-running
> old instance, not the moved one). Fixed by following this appliance's
> own documented philosophy — "Cattle: never repair it, rebuild it" — via
> the actual rebuild runbook procedure: `tofu taint` both
> `libvirt_domain.vm` and `libvirt_volume.system`, then re-run
> `create-nat64.sh` for a real destroy+recreate. That produced a
> genuinely fresh instance with the correct new addresses.

- [x] **Step 1: Apply**

```bash
.bin/create-nat64.sh
# then, since the in-place update didn't take on the live guest:
tofu -chdir=providers/kvm/nat64 taint module.nat64.libvirt_domain.vm
tofu -chdir=providers/kvm/nat64 taint module.nat64.libvirt_volume.system
.bin/create-nat64.sh
```

This is the actual cutover — `nat64-01` is rebuilt fresh on `br64` with
new ULA/IPv4 addresses. Appliance downtime during the rebuild.

- [x] **Step 2: Confirm the VM came back up on the new bridge with the new address**

```bash
ssh nat64admin@fd97:45c2:b3a1:64::64 "ip addr show lan; systemctl status tayga unbound"
```

Confirmed: `lan` shows `10.64.64.64/24` and `fd97:45c2:b3a1:64::64/64`;
`tayga`/`unbound` both `active (running)`; `cloud-init status: done` for
the genuinely fresh instance this time.

(Also confirmed: the script's own automated verification loop initially
timed out after rebuild — not an appliance problem, but a transient
reachability gap from the verifying machine's own network to the new
VLAN, resolved once that machine switched networks. See Task 7/10.)

---

## Task 7: MANUAL — repoint the UniFi static route

Not automatable — no `unifi_static_route` Terraform resource exists
anywhere in this repo; static routes are hand-maintained by design
(`providers/kvm/unifi-frr.conf`'s header, `docs/runbooks/control-plane-cold-start.md`).

- [x] In the UniFi Network UI: **Settings → Routing → Static Routes**,
  change the `64:ff9b::/96` route's next-hop from
  `fd97:45c2:b3a1:100::64` to `fd97:45c2:b3a1:64::64`.

Done by the user 2026-09-07. Confirmed working end-to-end (Task 10).

---

## Task 8: Fix `.bin/create-controlplane-cluster.sh`'s route logic

**Files:**
- Modify: `.bin/create-controlplane-cluster.sh`

- [x] **Step 1: Add the same on-link conditional `bootstrap.sh` already has (lines 179-202 there)**

```diff
 render_node() {
-  local name="$1" ula="$2" role="$3" base vip_block=""
+  local name="$1" ula="$2" role="$3" base vip_block="" routes_block=""
   base="${RENDER_DIR}/controlplane.yaml"
   [ "${role}" = "worker" ] && base="${RENDER_DIR}/worker.yaml"
   if [ "${role}" = "controlplane" ]; then
     vip_block="
         vip:
           ip: ${APISERVER_VIP}"
   fi
+  # An explicit route to NAT64_ULA is only installable when it's actually
+  # on-link for this node's own subnet -- the kernel rejects an off-link
+  # route outright ("no route to host"), which blocks cri/kubelet/etcd
+  # from ever starting. Same bug already fixed in bootstrap.sh
+  # (images/docker/talos-cluster-bootstrap/bootstrap.sh, "CORRECTED
+  # 2026-08-05"). Always false for controlplane after nat64-01 moved to
+  # its own VLAN (2026-09-06) -- nodes fall back to their existing
+  # default route, now symmetric since nat64-01 is genuinely off-link.
+  if [ "${NAT64_ULA%%::*}" = "${INFRA_SUBNET%%::*}" ]; then
+    routes_block="
+        routes:
+          - network: ${NAT64_PREFIX}
+            gateway: ${NAT64_ULA}"
+  fi
   cat > "${RENDER_DIR}/patch-${name}.yaml" <<EOF
 machine:
   network:
     hostname: ${name}
     interfaces:
       - deviceSelector:
           physical: true
         dhcp: false
         addresses:
-          - ${ula}/64
-        routes:
-          - network: ${NAT64_PREFIX}
-            gateway: ${NAT64_ULA}${vip_block}
+          - ${ula}/64${routes_block}${vip_block}
 EOF
```

- [x] **Step 2: Sanity-check the rendered YAML shape is still correct for both branches**

```bash
bash -n .bin/create-controlplane-cluster.sh # syntax check first
```

Confirmed: `SYNTAX_OK`.

---

## Task 9: Re-run `.bin/create-controlplane-cluster.sh`

> **DEVIATION (2026-09-07):** the script's apply loop
> (`.bin/create-controlplane-cluster.sh` lines 268-274) only pushes
> config to nodes it can't already reach at their static ULA over the
> secure Talos API — i.e. it's a first-boot bootstrap check, not a
> config-sync mechanism. Every one of the 6 already-running nodes hit that
> check and got skipped ("already configured ... — skipping"), so the
> corrected machine config was rendered correctly to disk
> (`.rendered/controlplane-*.yaml`, `.rendered/patch-all.yaml` — verified:
> new `nameservers: [fd97:45c2:b3a1:64::64]`, no `routes:` block, matching
> Task 8's fix) but never actually reached the live nodes via that script.
> Fixed by running `talosctl apply-config` directly against each of the 6
> nodes' own rendered files, one at a time, checking etcd health after
> each of the 3 control-plane nodes before moving to the next.

- [x] **Step 1: Re-render (via the script) then apply directly per-node (the script's own apply loop skips already-running nodes)**

```bash
.bin/create-controlplane-cluster.sh   # re-renders .rendered/*.yaml + patch-all.yaml; apply loop skips all 6 (already running)

# Applied directly instead, one at a time, control-plane nodes first:
talosctl --talosconfig providers/kvm/controlplane/.rendered/talosconfig apply-config \
  --nodes fd97:45c2:b3a1:100::11 --endpoints fd97:45c2:b3a1:100::11 \
  --file providers/kvm/controlplane/.rendered/controlplane-cp-1.yaml
# ...repeated for cp-2 (::12), cp-3 (::13), wk-1 (::21), wk-2 (::22), wk-3 (::23)
```

All 6 returned `Applied configuration without a reboot`. Picks up the new
`allocations.nat64_appliance.ula`/`.nat64_prefix` via `yq` at render time;
routes now conditional per Task 8 (correctly omitted, since
`fd97:45c2:b3a1:64` != `fd97:45c2:b3a1:100`).

- [x] **Step 2: Confirm no node lost etcd/cri**

```bash
talosctl -n fd97:45c2:b3a1:100::11,::12,::13 -e fd97:45c2:b3a1:100::10 service etcd
kubectl get nodes -o wide
```

Confirmed: etcd `Running`/`HEALTH OK` on all 3 control-plane nodes
throughout (checked after each individual apply, not just at the end);
`kubectl get nodes` shows all 6 `Ready`. Also confirmed via
`talosctl get resolvers` on cp-1 that the live `ResolverStatus` now
reports `["fd97:45c2:b3a1:64::64"]`.

---

## Task 10: Verify the new symmetric NAT64 path

- [x] **Step 1: From a VLAN-100 host with no host-level NAT64 route present**, run the runbook's existing verify commands against the **new** address:

```bash
ping -6 -c1 64:ff9b::8c52:7003
dig AAAA github.com @fd97:45c2:b3a1:64::64
curl -6 -sI https://github.com | head -1
```

Confirmed 2026-09-07, all passing with no host-level route present:
`dig` returns `64:ff9b::8c52:7204`; `ping6` to `64:ff9b::8c52:7003` 0%
loss; `curl -6 https://github.com` returns `HTTP/2 200`. Also re-ran the
**original failing reproduction case** end to end:
`curl https://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img`
(the exact URL from the original VM-provisioning bug report) now
completes in 3s, `SIZE:21430272`, `REMOTE_IP:64:ff9b::b9c7:6f85` — the
hairpin bug is confirmed gone.

---

## Task 11: Fix the `xkubernetescluster/composition.yaml` hardcode

**Files:**
- Modify: `clusters/controlplane/crossplane-resources/crossplane.environment-config.kvm-network.yaml`
- Modify: `applications/crossplane-resources/xkubernetescluster/composition.yaml`

Independent bug, no cutover dependency — do this any time.

- [x] **Step 1: Add top-level NAT64 fields to the network EnvironmentConfig**

```diff
 apiVersion: apiextensions.crossplane.io/v1beta1
 kind: EnvironmentConfig
 metadata:
   name: platform-kvm-network
 data:
+  nat64Ula: "fd97:45c2:b3a1:64::64"
+  nat64Prefix: "64:ff9b::/96"
   clusters:
     observability:
```

- [x] **Step 2: Template `NAT64_ULA`/`NAT64_PREFIX` from `$environment` the same way `INFRA_SUBNET` already is**

```diff
                             - name: INFRA_SUBNET
                               value: {{ $networkConfig.infraSubnet }}
                             - name: NAT64_ULA
-                              value: "fd97:45c2:b3a1:100::64"
+                              value: {{ $environment.nat64Ula }}
                             - name: NAT64_PREFIX
-                              value: "64:ff9b::/96"
+                              value: {{ $environment.nat64Prefix }}
```

(`$environment` is already bound at the top of this template block —
confirmed at line 500: `{{ $environment := index .context
"apiextensions.crossplane.io/environment" }}` — same binding
`$networkConfig` itself derives from.)

This fixes `images/docker/talos-cluster-bootstrap/bootstrap.sh`
transitively for every future claim-managed cluster — its own on-link
conditional (lines 179-202) is already correct and needs no change.

---

## Task 12: Documentation updates

- [x] **`docs/runbooks/nat64-appliance-rebuild.md`**: replace all
  `fd97:45c2:b3a1:100::64` examples with `fd97:45c2:b3a1:64::64`; **delete**
  the "Client routing quirk (VLAN 100 residents)" section — it no longer
  applies once `nat64-01` is off VLAN 100. (Added a short pointer note at
  the top to the ADR amendment/migration plan instead of deleting the
  history silently.)
- [x] **`docs/superpowers/specs/2026-07-11-m1-controlplane-cluster-design.md`**,
  **`providers/kvm/README.md`**: update the address reference. (The M1
  spec is a dated, point-in-time design doc, so added a "Superseded"
  note at the top rather than rewriting its historical body — matches
  this repo's own annotate-don't-rewrite convention; also flags that
  §6.2's "carries a static route" claim is no longer true for
  `controlplane`. README.md updated in place since it describes current
  state, not history.)
- [x] **`docs/adr/0023-ipv6-only-cluster-ula-nat64.md`**: add a new dated
  `## Amendment` section (matching the existing 2026-07-15 amendment
  style) noting the appliance moved to VLAN 64 on 2026-09-06 and why
  (ICMPv6-redirect hairpin bug, same class as the `observability`
  precedent).

---

## Task 13: Followup — different repo, note only

> **Done 2026-09-08.** Confirmed the workaround is no longer needed at
> all — `pcd-ce-hyp-01` (a VLAN 100 resident) now reaches the NAT64 path
> symmetrically via its plain default route with zero host-level route
> present: `curl` to an explicitly DNS64-resolved `64:ff9b::8c52:7204`
> returned `HTTP/2 200`. (`nat64-route.service` had already been silently
> failing every boot since the cutover — `RTNETLINK answers: No route to
> host`, since its hardcoded next-hop was the old dead address — so it
> wasn't doing anything by the time this was checked.) Removed
> `/etc/systemd/system/nat64-route.service` and
> `/usr/local/sbin/add-nat64-route.sh` from `pcd-ce-hyp-01`.

On the PCD hypervisor (`pcd-ce-deploy` repo, not part of this plan's file
changes), the `nat64-route.service` systemd unit's host route
(`64:ff9b::/96 via fd97:45c2:b3a1:100::64 dev br-tun`) now points at the
*old*, dead address. Remove or update it once Task 10's verification
passes, to avoid a stale route masking a real problem later.

---

## Automatable vs. manual summary

| Task | Type |
|---|---|
| 1-2. `XNetworkSegment` + `XUnifiNetwork` claims | Automated |
| 3-6. `network.yaml` / `nat64/main.tf` / module / `tofu apply` | Automated — real downtime window |
| 7. UniFi static route next-hop | **Manual (UniFi web UI)** |
| 8-9. Fix + re-run `create-controlplane-cluster.sh` | Automated |
| 10. Path verification | Manual (verification commands) |
| 11. `xkubernetescluster/composition.yaml` fix | Automated |
| 12. Docs/ADR updates | Automated (docs-only) |
| 13. PCD hypervisor cleanup | **Manual, different repo, followup only** |
