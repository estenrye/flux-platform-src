# Policy-Routing DaemonSet: Fix VLAN-100-Resident Client On-Link Reply Drops

Date: 2026-09-09
Status: **Proposed, gated behind manual validation.** The exact packet-drop
mechanism is still unconfirmed — this design proposes a routing-level
workaround, not a diagnosed-and-fixed root cause. Do not build the
DaemonSet before the plan's Task 1 (manual single-node validation) passes.
Parent: [docs/memory/node-gua-onlink-reply-unreliable.md](../../memory/node-gua-onlink-reply-unreliable.md)
(full investigation history). Related: the VLAN 179 BGP-peering migration
([2026-09-08-calico-bgp-peering-vlan179-design.md](2026-09-08-calico-bgp-peering-vlan179-design.md))
fixed a different, now-confirmed-separate bug on the same general path;
[ADR-22](../../adr/0022-unifi-bgp-load-balancer-vips.md) documents that
bug's history and the hairpin-through-gateway failure signature this
design must not reintroduce.

## 1. Problem

**Symptom** (confirmed live 2026-09-08/09, reproduced against two
independent real clients — `mf-ms-a2-01` and `pcd-ce-hyp-01` — and two
independent VIPs — the GUA ingress VIP and a purpose-built ULA-internal
VIP): any client genuinely resident on VLAN 100 calling a Gateway-fronted
Service on `controlplane` sees the connection hang. At the packet level,
`tcpdump` on the Talos node shows one of two equivalent failure shapes —
the TCP handshake completes and the next data packet (TLS ClientHello)
vanishes with no trace of a reply, or the node's SYN-ACK is repeatedly
retransmitted and never ACKed. Raw connectivity between node and client is
not the problem — a plain `ping6` between them is 30/30, 0% loss, sub-ms.

**Root cause**: every Talos node's `ens3` (the VLAN 100 NIC) carries
kernel-installed connected routes for *both* VLAN 100 prefixes handed out
via SLAAC/RA — the ULA (`fd97:45c2:b3a1:100::/64`, the node's own subnet)
and TFiber's PD-delegated GUA (`2607:3640:1064:270::/64`). Any destination
address in either prefix is on-link with `ens3` by the kernel's own
determination, so the node replies via direct NDP/L2 resolution instead of
normal routing. Something in that on-link reply path silently loses the
connection mid-flow. **The exact mechanism is not yet isolated** —
candidates include conntrack state, a driver/NIC offload bug, or something
gateway-side — but the discriminator (on-link vs. routed reply) is
confirmed regardless of mechanism.

**Not GUA-specific** (disproven 2026-09-09, correcting an earlier
conclusion in the memory file): a prior test showed ULA-sourced traffic
succeeding, but that client was on a *different VLAN* (200) entirely — off
VLAN 100's connected-route prefixes altogether, not evidence that ULA vs.
GUA is the real discriminator. `pcd-ce-hyp-01`, a genuinely VLAN-100
resident client (`fd97:45c2:b3a1:100::/64` address), hit the identical
failure signature against the ULA-internal VIP built in PRs #189-191.
**No VIP relocation can fix this for a VLAN-100-resident client** — the
fix has to live at the on-link-reply mechanism itself.

**Ruled out this session** (see memory file for full detail): raw NDP
reliability, Kubernetes `NetworkPolicy` content (unchanged since this
repo's first commit), Calico Service IP-pool selection (fixed separately,
PR #190), `EnvoyProxy` `ipFamily`/replica-count/traffic-policy
misconfiguration (fixed separately, PR #191) — none of these were the
cause of the underlying connectivity failure, only of secondary bugs found
along the way.

**Key risk this design must not reintroduce**: ADR-22 already documents a
hairpin-through-gateway bug for VLAN-100-resident clients' *outbound*
packets to a BGP-advertised VIP next-hop (fixed for the peering session by
VLAN 179; the client's own outbound leg still hairpins for VIP-destined
traffic since the VIP pools themselves are routed, not on-link, per the
2026-07-15 amendment). Forcing the *reply* leg through the gateway too
means deliberately routing around a technically-correct on-link decision —
if the gateway's hairpin handling for this traffic pattern is itself
unreliable, this "fix" could just move the failure rather than resolve it.
**This is the design's single highest-uncertainty question — validate
before building anything permanent** (see plan Task 1).

## 2. Design

Linux policy routing via a custom routing table, deployed and reconciled
by a privileged `hostNetwork` `DaemonSet` running on all 6 `controlplane`
nodes.

### 2.1 Routing table contents

A custom table (e.g. table `100`) containing:

- A route for each of VLAN 100's two prefixes
  (`fd97:45c2:b3a1:100::/64`, `2607:3640:1064:270::/64`) via the
  gateway's link-local next-hop (`fe80::ae8b:a9ff:fe6e:13de dev ens3`) —
  explicitly *not* on-link, forcing these destinations through normal
  routing instead of direct NDP.
- A `/128` on-link override for every *other* Talos node's own ULA
  address, so inter-node cluster traffic (etcd, kubelet, Calico's
  node-to-node BGP mesh — all confirmed to use the ULA `INFRA_SUBNET`)
  stays genuinely on-link and unaffected. The node's *own* address needs
  no explicit exception — the kernel's `local` table (priority 0) always
  wins for a node's own addresses before this custom rule is even
  consulted.
- **GUA peer exceptions are not needed**: nothing legitimately uses GUA
  addresses for inter-node cluster traffic, and Kubernetes `Node` objects
  only expose one `InternalIP` (the ULA) via the API this design queries
  — confirmed sufficient (Esten, 2026-09-09).

### 2.2 `ip rule` policy

Two rules matching destination prefix, both pointing at table `100`, at a
priority between the kernel's default `local` (0) and `main` (32766)
rules — e.g. priority `100`:

```
ip -6 rule add to fd97:45c2:b3a1:100::/64 lookup 100 priority 100
ip -6 rule add to 2607:3640:1064:270::/64 lookup 100 priority 100
```

### 2.3 Node-peer discovery (dynamic, not hardcoded)

The DaemonSet's own `ServiceAccount` token authenticates to the
Kubernetes API (`https://kubernetes.default.svc`) to list `Node` objects
and read `.status.addresses[type=InternalIP]` for the `/128` peer
exceptions — self-updating as the fleet scales, no manual list to keep in
sync. Requires a `ClusterRole` (`get`/`list`/`watch` on `nodes`, nothing
else) + `ClusterRoleBinding`, since `nodes` is cluster-scoped. No
circular dependency: the API server is reached over the pod network
(Calico), not via the `ens3` on-link path this design modifies.

### 2.4 DaemonSet shape

- `hostNetwork: true`, `securityContext.capabilities: [NET_ADMIN]` (not
  full `privileged` — narrower, matches least-privilege).
- Same control-plane toleration as `custom-proxy-config`
  (`node-role.kubernetes.io/control-plane: NoSchedule`), so it runs on
  all 6 nodes (3 control-plane + 3 workers), not just workers.
- Minimal image with `iproute2` + (`curl`+`jq`, or `kubectl` — either
  works; `curl`+`jq` keeps the image smaller).
- Reconcile loop, not a one-shot init: re-poll the Node API and
  re-assert the table/rules on an interval (e.g. every 60s) using
  idempotent operations (`ip route replace`, existence checks before
  `ip rule add`) — self-healing against drift, and necessary since this
  state lives only in the kernel and does not survive a node reboot
  (Talos has no persistent imperative config layer to stash it in).
- On a transient API-server failure, keep the last-applied table rather
  than wiping it — don't let a brief control-plane hiccup revert the fix.
- Interface name (`ens3`) has been consistently observed across all 6
  nodes this session, but consider having the script resolve it
  dynamically (matching against the known GUA/ULA prefix) rather than
  hardcoding, for robustness against a future NIC/interface-naming
  change.

### 2.5 Where this lives in the repo

A new Flux-managed application (e.g. `applications/vlan100-onlink-routing-fix/`),
following this repo's standard `base/` + `catalog.yaml` +
`kustomization.yaml` + `resources/` shape, deployed only to `controlplane`
(this is specific to this cluster's KVM host and VLAN 100/TFiber
situation, not a fleet-wide pattern).

## 3. Open questions requiring validation before committing

1. **Does this actually fix the drop, or relocate it into ADR-22's
   already-known hairpin bug?** Single highest-uncertainty question in
   this whole design — plan Task 1 validates manually, on one node, with
   a throwaway debug pod, before any permanent resource is built.
2. Is there any other currently-working on-link traffic pattern on VLAN
   100 this could disrupt, beyond the enumerated etcd/kubelet/Calico mesh
   exceptions? Worth an explicit sweep before fleet rollout.
3. Interface-name robustness (`ens3` hardcoded vs. dynamically resolved)
   — low risk given consistent observation, but cheap to make robust.

## 4. Consequences

- **If validated and it works**: closes out this entire investigation,
  unblocks `controlplane`'s VLAN 179 migration's final cutover step and
  the original goal — Designate's automatic retry loop successfully
  creating the pending `usmnblm01.rye.ninja` zone.
- **If it doesn't work**: strong evidence the problem is genuinely
  gateway-side (hairpin reliability, not an on-link-vs-routed
  distinction) — points the investigation at the third original candidate
  direction (a TFiber/gateway-side change) or toward directly isolating
  the drop mechanism (e.g. conntrack capture on the gateway during a live
  repro) before trying anything else routing-related.
- **Either way**: this adds a new, permanent, imperative (non-Talos-
  declarative) component running privileged on all 6 production nodes —
  a real maintenance/complexity cost, and a deliberate exception to
  Talos's immutable-host model. Worth weighing against simply living with
  the current limitation (no VLAN-100-resident clients calling fleet
  services) if the fix doesn't pan out cleanly.
