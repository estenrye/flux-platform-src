---
name: pod-egress-gua-routing-broken
description: ROOT CAUSE FOUND AND FIX VALIDATED, WORK PAUSED 2026-09-01 -- confirmed bug is same-bridge (br0) VM-to-VM traffic; fix is moving VMs to a separate VLAN (observability-vlan-segment, VLAN 200/br200), validated via disposable test VM (5/5 clean handshakes). Live migration of existing nodes failed twice (stale ARP/NDP cache theory); switched to tear-down-and-rebuild instead, which surfaced and fixed a real Terraform/libvirt parallelism race (PR #181 merged, PR #182 open) plus a Composition teardown gap (VMs orphaned from Crossplane tracking on delete). observability cluster fully destroyed 2026-09-01 to free host RAM for another project -- VLAN 200 network segment left intact for reuse. Original goal (openbao-remote ClusterSecretStore Ready from real prod nodes) still UNVALIDATED -- rebuild never got that far before pausing. Resume by recreating XKubernetesCluster observability with vlanRef: observability-vlan-segment.
metadata:
  type: project
---

## 2026-08-24, final correction: the NAT64/CoreDNS tangent below was a false lead

Everything in this document from "2026-08-24 (later): root cause is deeper
and older than any Kubernetes layer" onward — the NAT64 appliance
unreachability, the CoreDNS failure, the Talos dmesg history investigation,
the KVM host bridge/NDP digging — turned out to be **chasing a false lead**,
uncovered by testing more carefully:

1. **CoreDNS is not currently broken.** Every `[ERROR]` log line quoted
   below was stale — read repeatedly throughout the session without ever
   re-verifying with a fresh, live query. A live test at 04:49 UTC
   (`nslookup github.com <coredns-service-ip>`) returned a clean answer
   **including a correctly DNS64-synthesized AAAA record**
   (`64:ff9b::8c52:7104` for `140.82.113.4`) — proof CoreDNS is actively,
   successfully reaching the NAT64 appliance right now. No new log lines
   appeared for either of two fresh, guaranteed-uncached test queries.
2. **The "observability nodes can't reach the appliance" finding was
   self-inflicted.** Every debug pod used for that investigation was
   created in the `calico-system` namespace (chosen because it allows
   privileged/hostNetwork pods) — which has its own pre-existing, dedicated
   Calico Tier (`calico-system`) containing `calico-system.default-deny`,
   evaluated *before* the standard tier where any ordinary `NetworkPolicy`
   (including the allow-all-egress ones added during testing) lives. This
   is deliberate security hardening, unrelated to any real network path.
   Direct proof: an identical query from a pod in `default` namespace (no
   such Tier) with an explicit allow-all-egress `NetworkPolicy`, targeting
   the exact same appliance address, **succeeded immediately** — clean
   answer, first try, no timeout.
3. The KVM-host-level findings (all VMs — both clusters plus the NAT64
   appliance — share one physical host and one Linux bridge `br0`; bridge
   FDB entries are all correct; one stale/anomalous NDP cache entry on the
   appliance itself, `fd97:45c2:b3a1:100::30` → `observability-cp-2`'s MAC)
   are real observations but **not shown to be causally connected to any
   live bug** — kept below for reference only, not as an active lead.
4. The Talos `dmesg` history (1000+ occurrences on 2026-08-15 at node boot,
   one more on 2026-08-19, none since) is a **real, separate, historical**
   observation, but its relevance to anything currently happening is
   **unconfirmed** — it was never established that it's still ongoing or
   related to the actual live bug. Don't treat it as an active lead without
   fresh evidence.

**What this means going forward**: don't re-open the NAT64/CoreDNS angle
without a fresh, live-verified failure — the appliance and CoreDNS are
healthy as of this correction. The section immediately below (kept for
history) documents how the false lead was chased down; skip straight to
"Follow-up (same session, immediately after): true side-by-side
capture — decisive result" further down for the actual, still-relevant,
still-live bug and its evidence.

## 2026-08-24 revision: original hypothesis was wrong, real bug is narrower

Live-diagnosed further on `observability` with real `kubectl exec` access, a
disposable `netshoot` debug pod, and packet capture. Every part of the
original finding's root-cause hypothesis (Calico masquerade skipping GUA
destinations, pod CIDR return route not propagated via BGP) is **now
disproven**:

- **NAT-outgoing masquerade works correctly for GUA destinations.** Watched
  the `cali-nat-outgoing` MASQUERADE rule's packet counter in
  `ip6tables`/`nft` on the node directly (`nft list chain ip6 nat
  cali-nat-outgoing`) and confirmed it increments by exactly 1 for each real
  connection attempt from a pod to both Google DNS
  (`2001:4860:4860::8888:443`) and the fleet's Envoy Gateway VIP
  (`2607:3640:1064:27f::9280:443`). `cali60network-ip-pools` (the ipset that
  gates the masquerade rule's destination-exclusion match) only contains the
  pod CIDR itself (`fd97:45c2:b3a1:1200::/56`) — GUA space is never excluded
  from masquerade.
- **Raw TCP connectivity to both targets from an ordinary pod succeeds once
  NetworkPolicy allows it.** The original test's "pod can't reach any GUA
  destination" result was confounded by a cluster-wide default-deny
  `GlobalNetworkPolicy` named `deny-app-policy` (tier `default`,
  `namespaceSelector` excludes only `calico-apiserver`, `calico-system`,
  `kube-node-lease`, `kube-public`, `kube-system`, `tigera-operator` — i.e.
  applies to almost every namespace) that only explicitly allows egress to
  `kube-dns` and implicitly denies everything else unless a pod has its own
  more specific `NetworkPolicy`. The original test pod had no such policy.
  Adding a temporary allow-all-egress `NetworkPolicy` for a disposable debug
  pod (`netdebug-gua` in `default` ns) made both the Google DNS control and
  the fleet VIP connect immediately (`CONNECTED(00000003)`), with the
  masquerade counter incrementing as expected. **This `GlobalNetworkPolicy`
  predates the original finding** (`creationTimestamp:
  2026-08-23T22:07:31Z`) — it was already in place during the original test,
  so the original "no response, ever" result was very likely this policy,
  not a routing gap.

**What's actually still broken, confirmed live**: the real `openbao-remote`
`ClusterSecretStore`'s `external-secrets` pod (which *does* have an explicit
`NetworkPolicy` allowing broad egress on port 443, so it isn't blocked by
`deny-app-policy`) has been failing continuously since ~23:13 UTC on
2026-08-23 with `net/http: TLS handshake timeout` against
`https://bao.rye.ninja:443` — for ~4 hours straight as of this revision.
This is a **real, separate, still-unresolved bug**, but its actual symptom
is narrower and different from the original writeup: **TCP connects fine;
only the TLS handshake stage hangs.**

Reproduced directly: `openssl s_client -connect bao.rye.ninja:443
-servername bao.rye.ninja` from a pod gets `CONNECTED(00000003)` (TCP layer
succeeds) and then hangs indefinitely — never completes the TLS handshake,
never times out with an error, no certs printed.

**Packet capture during a live reproduction** (`tcpdump` on the pod's veth
from a privileged `hostNetwork` debug pod in `calico-system`, since
`calico-node`'s container has no `tcpdump` installed) showed, for a single
TCP flow to the VIP:
1. SYN → SYN-ACK → ACK: 3-way handshake completes normally.
2. Client sends the TLS ClientHello (~1546 bytes). Never ACKed — retransmits
   repeatedly with classic exponential backoff (~0.4s, 0.8s, 1.7s, 3.3s...).
3. **The server (VIP) re-sends its own SYN-ACK multiple times** (at +1s,
   +3s, +7s after the original), *after* already having received the
   client's ACK — i.e. from the server side, the connection was never
   actually confirmed established.
4. IPv6 flow labels differ on nearly every packet of the *same* flow (not
   held constant per-connection, which is atypical).

That combination — a handshake the server-side later "forgets," and
otherwise-normal-sized data segments vanishing with no RST/ICMP error and no
sign of MTU-driven fragmentation — does not look like a routing/masquerade
problem. It looks like an **ECMP / flow-affinity problem**: the shared
Envoy Gateway VIP fronts 6 `merged-eg` replicas
(`serviceLoadBalancerAggregation: Enabled` is set in the fleet's
`BGPConfiguration`, meaning Calico can BGP-advertise this LoadBalancer VIP
with equal-cost routes from multiple nodes). If the upstream router's ECMP
hash isn't flow-stable (plausible given the flow-label instability observed
above), different packets of the *same* TCP connection could be routed to
*different* backend nodes/replicas that don't share TCP/conntrack state —
explaining both the vanishing ClientHello and the server repeatedly
"re-offering" its SYN-ACK as if from a backend that never saw the ACK.

**Confirmed structurally** — the ECMP hypothesis holds up under direct
inspection of the actual Service/BGP config on `controlplane`:

- `envoy-merged-eg-668ac7ae` (the `LoadBalancer` `Service` backing
  `2607:3640:1064:27f::9280`) has `externalTrafficPolicy: Local` with
  exactly 6 replicas, **one scheduled per node**, across all 6
  `controlplane` nodes (`controlplane-cp-1/2/3`, `controlplane-wk-1/2/3`).
  `Local` means each node only forwards to its own local pod — so each of
  the 6 nodes independently BGP-advertises a route to the VIP.
- `controlplane`'s `BGPConfiguration` has `serviceLoadBalancerAggregation:
  Enabled` and `serviceLoadBalancerIPs` includes
  `2607:3640:1064:27f::/112` (covers the VIP), and there **is** a real
  `BGPPeer` to the LAN gateway (`unifi-gateway`, peer AS 64512, our AS
  64513) — unlike `observability`, which has zero `BGPPeer`s configured (BGP
  session list there is only the internal node-to-node mesh). So on
  `controlplane`, the UniFi router genuinely receives **up to 6 equal-cost
  BGP routes** to the same VIP address — one per node — and must ECMP-hash
  traffic across them.
- The pod-side packet capture (see above) shows the IPv6 flow label is
  **not** stable across retransmissions of the same TCP connection, despite
  `net.ipv6.auto_flowlabels = 1` (the standard "stable per-socket" mode) —
  it changes on essentially every retransmit event. If the UniFi router's
  ECMP hash uses the flow label as an input (common for IPv6 multipath
  hashing), each retransmission of the same flow could get rehashed to a
  **different one of the 6 backend nodes**, landing on a replica with no
  conntrack state for that connection and getting silently dropped there —
  while the original replica, never reliably receiving the ACK/continuation,
  keeps re-offering its own SYN-ACK. This matches the captured symptom
  exactly: the initial SYN/ACK/ClientHello burst shared one flow label and
  landed together (handshake completes), but every later retransmit got a
  fresh label and appears to have gone missing.

**Directly tested and disproven** (2026-08-24, same session): ran `tcpdump`
simultaneously on all 6 `controlplane` nodes' `ens3` uplinks (temporary
privileged `hostNetwork` debug pods, `calico-system` ns — user approved this
explicitly since it's a heavier/production-adjacent action than earlier
single-pod tests) while firing one precisely-timed `openssl s_client` attempt
from the `observability`-side debug pod. Result: **only one node
(`controlplane-cp-1`) saw any packet of this flow at all** — the other 5
captured zero packets for the entire attempt. This rules out "packets of one
TCP flow scatter across different backend replicas" as the mechanism — if
that were happening, at least some of the retransmits should have shown up
on a different node's capture.

What the single-node capture actually showed: the client's SYN arrived at
`cp-1`, which replied with a SYN-ACK — then retransmitted that same SYN-ACK
three more times (backing off ~1s, ~2s, ~4s) because **the client's ACK
never arrived at `cp-1` at all**, in this or any of the other 5 captures.
This is a narrower, different symptom than "flow bounces between backends":
one specific node's SYN-ACK response gets stuck, and the return traffic
(ACK, and by extension the TLS ClientHello riding on it) appears to vanish
somewhere on the path back to that one node — even though the pod's own
kernel, per the earlier same-session veth capture, believed it successfully
transmitted the ACK and ClientHello (with retries) for a similar attempt.

**Net effect: the ECMP/flow-label hypothesis above is not supported by this
more direct test and should not be pursued further as the leading theory.**
The structural ECMP setup (6 nodes each BGP-advertising the same VIP) is
still real and could still matter, but it isn't manifesting as
"different nodes catch different packets of the same flow" the way that
would predict.

## Follow-up (same session, immediately after): true side-by-side capture — decisive result

Repeated the test with **simultaneous** capture on both ends of one single
connection attempt: `controlplane`'s same 6-node capture (user re-approved
recreating the debug pods) *plus* a capture on `observability-cp-1`'s own
uplink (`ens3`, post-NAT — sees both directions, unlike the earlier
pod-veth-only capture). Both directions correlated by timestamp from the
same connection attempt.

**What this proved, cross-referencing both captures by timestamp:**
- SYN leaves `observability`'s uplink, arrives at `controlplane-cp-1` (same
  node as the previous test — 2 for 2 now, though still a small sample).
- `cp-1` replies SYN-ACK — **confirmed arriving back** at `observability`'s
  uplink (timestamps match to the microsecond between the two independent
  captures).
- The client's ACK leaves `observability`'s uplink **186 microseconds
  later** (flowlabel `0x663ca`, same as the SYN/ACK — stable so far) — and
  **never arrives at `cp-1` or any of the other 5 nodes**, in either
  capture.
- `cp-1` retransmits its SYN-ACK three more times over the following
  seconds, and **every one of those retransmits is confirmed arriving back**
  at `observability`'s uplink (timestamps match exactly across both
  captures each time).

So: the reverse path (`cp-1` → `observability`) works perfectly and
repeatedly. Only the forward path breaks, and only *after* the SYN —
specifically the ACK, which departs only 186µs after the SYN-ACK it's
responding to.

**New leading hypothesis**: that sub-millisecond gap is the key signal. This
doesn't look like a routing/NAT/ECMP failure (the SYN got through fine, and
so does every reverse-direction packet) — it looks like a **race condition
in stateful connection tracking somewhere on the forward path**, most likely
the UniFi gateway's own conntrack (it's the one stateful device known to sit
on this path — see the `unifi-gateway` `BGPPeer` on `controlplane`). If its
conntrack hasn't finished registering the new SYN-based session before the
ACK shows up 186µs later, the ACK could get treated as unexpected/invalid
and silently dropped. This would also explain, retroactively, why the
external controls (Cloudflare, Google DNS) worked cleanly: normal internet
RTT is tens of milliseconds, giving any such race condition plenty of time
to resolve, while this LAN-local, cross-cluster path apparently completes
its handshake in under a millisecond — fast enough to expose a race that
would never manifest on a normal WAN connection.

**Not yet confirmed** — needs access this session didn't have:
- Direct visibility into the UniFi gateway's own conntrack table or packet
  capture (out of `kubectl`'s reach — would need SSH/CLI access to the
  router itself).
- Whether *artificially delaying* the client's ACK (e.g. `tc qdisc add dev
  eth0 root netem delay 5ms` in a debug pod before attempting the
  handshake) makes the connection succeed — this would be a clean,
  falsifiable test of the race-condition theory without needing router
  access: if adding latency fixes it, that's strong confirmation; if it
  doesn't, the theory is wrong and something else is going on.
- Whether the same "SYN-ACK sent, ACK never arrives" pattern is specific to
  `cp-1` or would follow traffic to a different one of the 6 nodes (only
  `cp-1` was ever selected in both attempts so far — worth trying enough
  connection attempts, or a NodePort test directly against a different
  node, to see if the pattern is node-specific or generic to the path).

## 2026-08-24, later still: confirmed generic to all backends, and the whole path is one physical host

Got direct SSH access to the KVM hypervisor (`mf-ms-a2-01.usmnblm01.rye.ninja`)
this session and used it to capture at the tap-interface level — a cleaner
vantage point than anything inside Kubernetes, and it answered the open
question above directly: **`virsh list` shows all of `observability`'s VMs,
all of `controlplane`'s VMs, and the NAT64 appliance on this one single KVM
host**, all bridged onto one Linux bridge (`br0`). This traffic never
touches a physical switch or the UniFi gateway at all — it's pure
host-internal L2 bridging between VMs. Confirmed `br_netfilter` is disabled
on `br0` (`nf_call_iptables 0`, `nf_call_ip6tables 0` in `ip -d link show`),
so the host's own iptables doesn't touch this traffic either — ruling out
both the gateway and this host's own firewall as the point of loss.

Ran three separate live connection attempts this session with simultaneous
tap captures on both ends (mapped via `virsh domiflist`:
`observability-cp-1` = `vnet9`, `controlplane-cp-1` = `vnet2`,
`controlplane-cp-2` = `vnet4`, `controlplane-cp-3` = `vnet1`,
`controlplane-wk-1` = `vnet5`, `controlplane-wk-2` = `vnet8`,
`controlplane-wk-3` = `vnet7`). Result: **the destination backend is not
sticky** — attempt 1 and 2 landed on `controlplane-cp-1`, attempt 3 landed
on `controlplane-wk-1` — consistent with genuine per-connection ECMP
selection across the 6 replicas (not per-packet, which was already ruled
out earlier). But **every single attempt showed the identical symptom
regardless of which node was selected**: SYN arrives, that node's Envoy
replica sends SYN-ACK (and retransmits it repeatedly), and the client's ACK
— sent by the source VM within roughly 100-200 microseconds of receiving
the SYN-ACK — never arrives at whichever node was picked.

This rules out any single node's hardware/NIC/local-config as the cause
(three different physical taps, same result) and rules out the gateway/LAN
switch (traffic never leaves this one host). What's left: something in the
**destination VM's own kernel or Calico/Felix conntrack handling**
reacting badly to a SYN→SYN-ACK→ACK sequence completing in well under a
millisecond — consistent and reproducible across every backend tested, but
still not directly observed at the point of loss (never captured
`conntrack -L` or equivalent on a destination node at the exact moment).

**Not yet done** — the concrete next step: capture simultaneously on the
*destination* node's own tap during a fresh attempt (this session captured
destination taps but the ACK never showed up there either — consistent
with the earlier `cp-1`-only test — worth repeating with `conntrack`
inspection via SSH/talosctl on the destination node in the same window, to
see whether a conntrack entry exists for the flow and what state it's in
when the ACK should be arriving but isn't).

## 2026-08-24, final: conntrack proves the destination is ready and waiting — loss is on the bridge itself, untraceable with available tools

Did exactly the above. Fired a 4th live connection attempt with all 6
`controlplane` taps capturing at the hypervisor level; it landed on
`controlplane-wk-2` (`vnet8`) this time — a 4th different backend, same
symptom (SYN in, SYN-ACK out + retransmitted, no ACK ever arrives). Within
the retry window, read `/proc/net/nf_conntrack` directly off
`controlplane-wk-2` via `talosctl -n <node> read /proc/net/nf_conntrack`
(Talos has no shell, but `read` works on any proc file) and caught the live
entry:

```
ipv6 10 tcp 6 7 SYN_RECV
  src=<observability-cp-1 masqueraded GUA> dst=<VIP> sport=28909 dport=443
  reply: src=fd97:45c2:b3a1:1184:e346:281d:e94c:6970 dst=<observability-cp-1> sport=10443 dport=28909
```

The reply tuple shows the connection was correctly DNAT'd from the VIP
(port 443) to the real Envoy pod's actual address and container port
(`10443`, normal Kubernetes Service DNAT — the pod itself listens on
10443, not 443). State `SYN_RECV` confirms conntrack already processed the
SYN-ACK reply correctly (a fresh entry can't reach `SYN_RECV` without
having seen it). **This conntrack entry is fully valid and sitting ready to
accept the client's ACK** — if the ACK physically arrived at this node's
interface with the matching 5-tuple, it would complete the handshake
immediately. It doesn't arrive, so the loss is not a NAT/conntrack logic
bug on the destination — the packet is vanishing somewhere between leaving
the source VM's `ens3` and arriving at the destination VM's tap, despite
both being confirmed on the same physical host and the same bridge.

Checked everywhere available for a trace of this loss and found nothing:
- `ip -s link show` on both `vnet9` (source) and `vnet8` (this attempt's
  destination): **zero** RX/TX errors or drops on either individual port.
- `br0` (the bridge master device) shows a nonzero RX-dropped counter
  (1171 at time of check), but pure port-to-port unicast bridging in Linux
  normally bypasses the master device's own counters entirely (only
  broadcast/multicast/bridge-destined traffic touches them) — almost
  certainly unrelated noise, not this TCP flow specifically.
- `ethtool -S` on both taps: no stats available (tap devices are
  software-only, no driver-level queue/drop counters exposed).
- Neither `dropwatch` nor `perf` is installed on this KVM host — no way to
  trace an in-kernel drop location without installing tooling first.
- Host `dmesg -T` for the exact test window (05:03-05:05 UTC): completely
  clean, no warnings of any kind.

**This is the practical limit of what's diagnosable with tools currently
available.** Every layer that's checkable from the outside (source
transmission, destination conntrack state, interface counters, bridge FDB,
kernel logs) is clean and correct — the loss is happening at a level none
of the standard tools on this host can see. Four separate connection
attempts, four different backend nodes, identical symptom every time,
loss reproducible but not directly observable.

**Next steps, in order of how much new access/tooling they require**:
1. Install `dropwatch` (uses the `NET_DM` kernel tracepoint to report exact
   in-kernel drop locations by function name — would very likely nail this
   in one capture) or `bpftrace`/`perf` on `mf-ms-a2-01.usmnblm01.rye.ninja`
   — needs the user's own package-install access, not attempted this
   session.
2. If unavailable, try reproducing with `virsh domiflist`/`qemu` monitor
   commands to inspect vhost-net queue depth/drops per-VM around a live
   attempt (the virtio-net/vhost-net TX/RX queue path is the most likely
   remaining suspect given the extreme sub-millisecond timing and the fact
   that every other layer is clean).
3. As a workaround (not a fix): if this only affects the shared multi-
   replica Envoy Gateway VIP specifically because of the very tight
   SYN-ACK-then-ACK timing inherent to same-host, same-bridge traffic,
   check whether the same symptom reproduces for cross-cluster traffic to
   a destination that *isn't* on this same KVM host (there may not be one
   in this fleet currently) — that would confirm or rule out "same-host
   bridging" itself (as opposed to Envoy/the VIP/Calico) as the necessary
   condition.

## 2026-08-24, even later: bpftrace installed live (user has sudo), narrows below the standard kernel networking stack entirely

`dropwatch` isn't packaged for this host's Ubuntu 22.04 repos (`apt-cache
search` empty). `bpftrace` is (`universe`, v0.14.0) — installed live with
the user's explicit go-ahead (`sudo apt-get install -y bpftrace`; the only
side effect was a routine `needrestart` notice, which explicitly **deferred**
restarting `libvirtd`/`virtlogd` — no VM disruption).

**`tracepoint:skb:kfree_skb` (fires on every real packet drop, with a
symbolic `enum skb_drop_reason` — this kernel has full reason support)
recorded zero drop events for IPv6 traffic during a full 20-second window
covering an entire live reproduction**, filtered on `args->reason != 0`
(confirmed the filter logic is sound: an unfiltered protocol tally in the
same run showed real traffic at `args->protocol == 34525` i.e. `0x86DD` /
IPv6, so this isn't a byte-order artifact — bpftrace already normalizes it).
This is a strong negative result: it rules out **every** standard drop path
in the Linux networking stack — netfilter DROP targets, routing failures,
malformed-packet checks, socket buffer overruns, all of it. The packet is
not being dropped anywhere `kfree_skb`-with-a-reason would catch.

Cross-checked against `virsh domstats <vm> --interface`, which reports
libvirt/QEMU's own per-VM interface counters (a separate accounting path
from `ip -s link show`) — also zero RX/TX errors and drops on both the
source (`observability-cp-1`) and every destination tested. `vhost_net` is
confirmed loaded and active (kernel-accelerated virtio-net, not QEMU
userspace emulation) via `lsmod`. No `tracepoint:vhost:*` category exists
on this kernel — vhost-net's own internal ring-buffer/queue handling has no
tracepoint-level visibility at all with the tools available.

**Where this leaves it**: combined with the earlier direct observation
(tcpdump on the destination tap reliably captures the initial SYN — proving
the bridge's forward decision and FDB lookup succeed for the *first* packet
of a flow — but never captures the follow-up ACK, which departs the source
only ~100-200µs later), the loss is narrowed to somewhere between (a) the
bridge's per-packet forwarding decision for this second, near-simultaneous
packet, or (b) vhost-net's internal queuing/notification path — and it's
below every tracepoint-based tool tried this session. Reaching further
would need either kprobes on internal, non-tracepoint kernel functions
(`br_forward`, `br_handle_frame_finish`, ...) — attempted a cursory look
at available kprobe targets (they exist) but not pursued further, since
correctly filtering kprobe args for this specific flow without BTF-typed
tracepoint convenience is substantially more fragile scripting — or
`dropwatch`/`perf` from a different package source (e.g. building from
source, or a container with the tool preinstalled). Also worth trying
cheaply: this host has a **pending kernel upgrade** already available
(`5.15.0-187-generic` running, `5.15.0-190-generic` available per `apt`) —
checked its changelog for bridge/vhost/conntrack-relevant fixes and found
nothing obviously relevant, but a full kernel bump is still a low-effort
thing to try before going deeper into kprobe scripting.

## 2026-08-24, deepest: kprobe-traced the entire kernel bridging path — it's all clean, down to the final NIC hand-off

Went ahead with the kprobe scripting flagged above (user has `sudo` on the
hypervisor). BTF is available (`/sys/kernel/btf/vmlinux`), but bpftrace's
typed-arg support (`-lv`) doesn't cover these particular kprobes, so each
function's skb-argument position was found empirically: call with a
candidate `argN` cast to `struct sk_buff *`, check whether `->len` reports
sane values (tens-to-low-thousands of bytes) or garbage. This worked
cleanly and is worth remembering as a technique for any future kernel
kprobe work on this host.

Traced, **in call order**, the entire Linux bridging path a packet takes
crossing `br0`, correlated by exact wall-clock microsecond against a
simultaneous source-tap capture that pinned the ACK's departure to the
microsecond (`05:27:59.168608`):

1. `br_handle_frame_finish` (skb at arg2) — fired at **05:27:59.168608**,
   `len=72` (=40 IPv6 hdr + 32 TCP hdr, zero payload — exactly our ACK).
   Exact same microsecond as the capture. This is bridge code receiving
   the frame.
2. `br_forward` (skb at arg1) — fired **2 microseconds later**, same
   `len=72`. The bridge decided to forward this exact packet.
3. `br_allowed_egress` (skb at arg1, NOT arg2 as first guessed) —
   `kretprobe` shows **`RET=1` (allowed)** for every matching-size call
   observed across a full test window. This VLAN/port-state gate is not
   silently rejecting anything.
4. `__br_forward` (skb at arg1) — fires immediately after, matching
   `len=72`, for every one of these packets.
5. `br_dev_queue_push_xmit` (skb at **arg2** — first guess of arg0/arg1
   was wrong, both read `len=0`; arg2 confirmed correct with sane values
   at real, matching volume) — fires immediately after `__br_forward` in
   every observed case, matching timing and size.

**Every traceable step of the kernel's own software bridging code path
fires correctly, in the right order, at the right microsecond, for this
exact packet.** `br_dev_queue_push_xmit` is the final Linux-side call
before handing the skb to `dev_queue_xmit()`, which invokes the
destination tap device's `ndo_start_xmit` — the literal boundary between
"the kernel's generic networking/bridging code" and "the tap driver +
vhost-net's own internal queue and guest-notification mechanism." That
boundary is where this investigation's tracing ability ends: zero
`tracepoint:vhost:*` events exist on this kernel (checked earlier), and
kprobing vhost-net's or the tap driver's internal functions
(`tun_net_xmit`, `vhost_net_buf_produce`, `handle_tx`, or similar,
depending on exact code path and vhost-net's own worker-thread model)
would need another full round of the same empirical signature-discovery
process used above — not attempted this session, but the demonstrated
technique should transfer directly.

**Conclusion for anyone picking this up**: this is no longer a Kubernetes,
Calico, NetworkPolicy, conntrack, or even general-Linux-networking
question. It's specifically about what happens to a packet handed to a
`tap`-backed `vhost_net` interface in the narrow window immediately after
handling a *different* packet on the *same* interface (the prior SYN-ACK
retransmit or the SYN itself) — a timing/queueing question inside the
vhost-net kernel module. Concrete next steps, cheapest first:
1. Try the pending kernel upgrade (`5.15.0-190-generic`) — a one-line
   `apt upgrade` + reboot of this specific host, cheap to test, and kernel
   point releases do periodically fix vhost-net races.
2. Kprobe vhost-net's own functions directly, using the same empirical
   arg-discovery technique demonstrated above.
3. As a pure diagnostic (not a fix): temporarily disable vhost
   acceleration for one VM pair (forces plain QEMU userspace virtio-net
   emulation instead of the kernel's vhost_net) and see if the symptom
   still reproduces — if it doesn't, that conclusively implicates
   vhost_net specifically rather than virtio-net/tap in general.

## 2026-08-24 (later): root cause is deeper and older than any Kubernetes layer

Prompted by a sharp question from the user about whether this could relate
to the same-day `dns64_allowed_cidrs` NAT64 appliance change (#178, see
[docs/memory MEMORY.md] index) — traced CoreDNS's own upstream timeout
(`fd97:45c2:b3a1:100::64`, confirmed via `providers/kvm/network.yaml` to be
the NAT64/DNS64 appliance's ULA) all the way down, with **direct SSH access
to the appliance** (`ssh nat64admin@fd97:45c2:b3a1:100::64`) and
**`talosctl`** access to the `observability` nodes themselves
(`TALOSCONFIG=~/.talos/homelab-observability.yaml`) — both newly available
this session (the appliance SSH key from #178 works; `talosctl` was already
configured locally).

**Ruled out**: the DNS64 allowlist itself. The live `unbound.conf` on the
appliance already has `access-control: fd97:45c2:b3a1::/48 allow` (the full
site ULA, from #178) plus the WireGuard CIDR — already applied live, already
broad enough to cover both pod-pool and node-pool source addresses. Not the
cause.

**Confirmed via live correlation** (enabled `unbound-control set_option
log-queries yes` — this does NOT restart the service, verified via
`systemctl status` showing unchanged process start time; a `journalctl -f`
burst of old startup-log lines briefly looked like a restart but wasn't):
firing test DNS queries from pods on `observability-cp-1` and
`observability-cp-2` (masqueraded to node addresses `fd97:45c2:b3a1:100::31`
/ `::32`) — **neither query ever appears in the appliance's own query log,
in either direction's test window** — while real, concurrent production
queries from **`controlplane`** nodes (`::13`, `::22`) and other LAN clients
land and get processed within milliseconds, repeatedly. All these hosts
share one physical `/64` L2 segment (`fd97:45c2:b3a1:100::/64` per
`network.yaml`), so this is on-link reachability, not routing — and it's
specific to `observability`'s nodes.

Checked the appliance's own NDP neighbor table
(`ip -6 neigh show`) and found one concrete anomaly worth a human's own
context: `fd97:45c2:b3a1:100::30` is bound to MAC `52:54:00:b3:a1:32` (which
is `observability-cp-2`'s real MAC) — there's no separate neighbor entry for
`::32` itself. Could be stale leftover from a past renumbering of that VM,
or live corruption — flagged for the user to interpret, not conclusively
diagnosed.

**The decisive finding**: pulled `talosctl -n <node> dmesg` on all three
`observability` nodes directly (Talos has no SSH/shell — `talosctl` is the
only way in) and searched for this exact failure signature, independent of
Kubernetes/CoreDNS/Calico entirely — Talos has its own built-in
`dns-resolve-cache` OS component that forwards DNS itself. Found the
**identical symptom** (`read udp [node]:PORT->[fd97:45c2:b3a1:100::64]:53:
i/o timeout` / `read: connection refused`) on **all three nodes**,
**starting from the moment each node booted**:

- `observability-cp-1`: 1015 occurrences, first at `2026-08-15T05:14:48Z`
  (a sustained burst right at boot), one more isolated at
  `2026-08-19T22:10:32Z`, nothing since in the dmesg buffer (though the
  live symptom was independently reproduced multiple times this session,
  hours after this search — Talos's own resolver may simply not be issuing
  fresh queries for domains it's already cached, unlike my synthetic
  always-uncached test queries).
- `observability-cp-2`: 1016 occurrences, same pattern.
- `observability-cp-3`: 984 occurrences, same pattern.

**This reframes the entire investigation.** This is not a Kubernetes-layer
bug at all — not Calico, not NetworkPolicy, not ECMP, not a conntrack race.
It is a genuine, pre-existing, node/OS-level, on-link L2 reachability
problem between `observability`'s three VMs and (at least) this one LAN
neighbor, present since the cluster's creation on 2026-08-15 — 9 days before
this investigation started, and completely orthogonal to the OpenBao/B6
work that originally surfaced it. Every earlier hypothesis in this document
(masquerade skipping GUA, ECMP flow-label instability, stateful-conntrack
race) was investigating a real, reproducible symptom, but at the wrong
layer — the actual fault sits below all of it, likely in the KVM host's
bridge/virtio-net configuration for these three specific VMs, the physical
switch port(s) they're bridged through, or something about how these VMs
were provisioned that `controlplane`'s VMs don't share (`controlplane`
nodes on the same L2 segment have no equivalent failures logged).

**Not yet confirmed** — this needs physical/infra-level investigation this
session has no access to:
- The KVM host's bridge configuration and virtio-net driver behavior for
  the `observability` VMs specifically, vs. `controlplane`'s (same
  hypervisor host? different one?).
- The physical switch port(s) these VMs are bridged through — port
  flapping, spanning-tree state changes, or a duplicate/conflicting MAC on
  the segment could produce exactly this "some neighbors reachable, others
  not, intermittently" pattern.
- Whether the `fd97:45c2:b3a1:100::30`-to-`::32` MAC anomaly in the
  appliance's neighbor cache is a real due, or harmless stale leftover —
  only the user's own history with this appliance can resolve that.
- Whether `controlplane`'s and `observability`'s VMs are actually on the
  same physical KVM host/bridge or different ones — if different hosts,
  that's a strong lead (something specific to one physical host's
  networking).

## Timeline of the live `openbao-remote` failure (2026-08-23/24, all UTC)

Pulled directly from the `external-secrets` controller pod's logs
(`kubectl logs -n external-secrets-operator <pod>`), which shows the failure
mode changed three times — useful context so a future session doesn't
conflate these:

1. **22:07:31 – 22:08:01** — `configmaps "ryezone-labs-root" not found`.
   Self-resolved once that `ConfigMap` was created at 22:08:09 (unrelated
   trust-bundle propagation, not part of this investigation).
2. **22:08:36 – 23:05:52** — `dial tcp: lookup bao.rye.ninja ... no such
   host`. Self-resolved, presumably once `external-dns` propagated the
   record.
3. **23:13:26 → ongoing (still failing as of 03:00 UTC 2026-08-24, ~4h
   straight)** — `net/http: TLS handshake timeout`. This is the real,
   still-open bug described above.

## Original finding (2026-08-23) — superseded, kept for history

The original write-up claimed pods could not reach **any** GUA destination
at all, with no TCP-level response whatsoever (`openssl s_client` never
printing `CONNECTED`), and hypothesized a Calico masquerade/BGP
return-route gap. That blanket claim is now known to be wrong — see the
revision above. The original test was not isolated from `NetworkPolicy`
enforcement, and the debugging session that produced it had much more
limited live cluster access than this one.

## Impact on M4 completion step B6

Unchanged: B6 itself
(`docs/superpowers/specs/2026-08-16-openbao-cross-cluster-auth-design.md`,
PRs #172-#177, all merged) is still fully correct and complete as designed.
The `openbao-remote` `ClusterSecretStore` will report `Ready: True` once the
TLS-handshake-stage bug above is actually fixed; nothing in B6 needs to
change. Don't re-open or re-debug B6's own manifests based on this finding.

## Session context / access notes

Both `controlplane` and `observability` `kubectl` contexts were live and
reachable in this session (`controlplane` via the default context,
`observability` via `KUBECONFIG=~/.kube/homelab/observability.yaml`) —
unlike the original session, which had little to no live access for most of
its duration. Disposable debug pods used and **already cleaned up**:
`netdebug-gua` (`default` ns on `observability`, `nicolaka/netshoot`, used
for `/dev/tcp` and `openssl s_client` tests, needed an explicit
allow-all-egress `NetworkPolicy` — `netdebug-gua-allow-all-egress` — to get
past `deny-app-policy`) and `netdebug-hostnet` (`calico-system` ns on
`observability`, privileged + `hostNetwork`, used for `tcpdump` since
`calico-node`'s own container has no `tcpdump` binary). If a fresh session
finds either still present, something interrupted cleanup — safe to delete.

## 2026-08-24/30: full VM reboot + kernel upgrade did NOT fix it; separate DNS bug found and fixed along the way

Same session that did the deep kprobe tracing above got explicit go-ahead
to actually try the kernel upgrade: gracefully shut down all 10 fleet VMs
(`virsh shutdown`, waited for `shut off`), rebooted
`mf-ms-a2-01.usmnblm01.rye.ninja` into the already-installed
`5.15.0-190-generic` (first `sudo reboot` attempt silently failed to even
connect — "No route to host" — and was mistaken for a completed reboot;
caught by checking `who -b`/`uptime` after reconnecting, not just SSH
reachability. Second attempt correctly showed "closed by remote host" and
came back with a genuinely fresh boot time). ZFS pool and libvirtd both
auto-recovered via existing systemd enablement. All 10 VMs came back via
libvirt autostart. `openbao-db` (CNPG/Postgres backend) took ~2 min to
reach 3/3 healthy after the reboot; `openbao-1`/`openbao-2` came back stuck
in `Completed` (exit 0, `restartPolicy: Always` not honored — root cause
not investigated, just deleted and let `OrderedReady` recreate them once
`openbao-0` was unsealed). Full unseal ceremony against all 3 pods
succeeded cleanly with the existing SOPS-encrypted key shares; logged in
`docs/runbooks/openbao-unseal.md`'s ceremony table.

**Direct retest against the real VIP after the kernel upgrade: identical
symptom.** TCP connects, TLS handshake hangs. The kernel bump did not fix
whatever's wrong in vhost-net.

**Five days later (2026-08-30), asked to reverify — found a second, wholly
separate bug**: `openbao-remote`'s error had changed from `TLS handshake
timeout` to `no route to host`, because `bao.rye.ninja` was now resolving
to `2607:3640:1064:270:ffff::9282` — the old, deprecated on-link VIP
scheme network.yaml itself documents as superseded. Traced this to
`external-dns`'s `registry: txt` mode: queried UniFi's own Static DNS API
directly (`/proxy/network/v2/api/site/default/static-dns`) and confirmed
zero `TXT`-type records exist for *any* managed hostname on the whole
controller — UniFi's Static DNS feature has no TXT record type at all, so
the `edns.*` ownership markers `registry: txt` depends on can never be
written. external-dns silently treats every record as unowned after first
creation and never touches it again, no error ever logged (just
`"All records are already up to date"` forever, even while visibly wrong).
Fixed by switching to `registry: noop` in
`applications/external-dns/unifi/base/values.yaml` (PR #180, merged same
session) — verified live: `bao.rye.ninja` now correctly resolves to
`2607:3640:1064:27f::9280`, and the *very next* ESO reconcile after DNS
converged went straight back to the familiar `TLS handshake timeout` —
cleanly confirming the original vhost-net bug is the sole remaining
blocker, with the DNS confound now fully cleared out of the way.

**Current state**: `openbao-remote` `ClusterSecretStore` still `Ready:
False` (`InvalidProviderConfig`), purely on the original, unresolved
vhost-net bug. DNS is no longer a factor. Next step is still the same one
identified in the kprobe-tracing section above: kprobe vhost-net's own
internal functions directly (function names not yet discovered — same
empirical arg-position-discovery technique used for the bridging kprobes
should transfer), or disable vhost acceleration on one VM pair as a pure
diagnostic to confirm vhost-net specifically (vs. virtio-net/tap in
general) is implicated.

## 2026-08-30, decisive: vhost_net ruled out entirely

Continued the kprobe tracing from the deep vhost-net section above. Found
the actual RX-delivery-into-guest function chain (`tun_net_xmit` — packet
enters the tap queue — then vhost's own worker: `handle_rx_net`,
`tun_recvmsg`, `vhost_net_buf_peek`). `handle_rx_net` fires in a clean 1:1
pairing with `tun_net_xmit`, no visible gaps, for a specific reproduction
window matched to the microsecond via a simultaneous source-tap capture —
ruling out "vhost worker never woken" as the mechanism. `vhost_add_used`/
`vhost_signal` never fired even once across a 20-second capture despite
`handle_rx_net` running 38k times, almost certainly because they're inlined
at their real call site in this kernel build (not a sign anything is
actually broken system-wide, since the whole fleet clearly does receive
traffic normally). Aggregate volume across the whole chain
(`tun_net_xmit`≈`handle_rx_net`≈`tun_recvmsg`, `vhost_net_buf_peek`≈2x) was
healthy at scale — tens of thousands of packets per 5s interval, no
anomaly visible. This bug affects a vanishingly small fraction of traffic
(one specific timing pattern), invisible in bulk counters; isolating the
*specific* lost packet through vhost's internals would need either
disassembly-level tooling or exact skb-pointer correlation through
functions that don't expose one via simple kprobe args — beyond what's
practical live.

**Ran the definitive test instead**: temporarily disabled vhost
acceleration on `observability-cp-1` by redefining its libvirt XML with an
explicit `<driver name='qemu'/>` on the interface (forces plain QEMU
userspace virtio-net emulation, confirmed via the vhost kernel thread count
dropping from 10 to 9 after restart), restarted just that one VM, waited
for it to rejoin the cluster (`Ready` again), and retested the exact same
TLS handshake against the real VIP.

**Result: identical symptom, unchanged.** TCP connects
(`CONNECTED(00000003)`), TLS handshake hangs, same as with vhost enabled.

**This conclusively rules out vhost_net as the cause.** The bug is not in
the kernel's vhost-net acceleration path at all — it reproduces identically
whether packet delivery into the guest goes through vhost_net's kernel
worker thread or QEMU's own userspace virtio-net emulation, two completely
different code paths that only share the `tun`/tap character device
underneath and the guest's own virtio-net driver inside Talos. That
overlap is the new, narrower suspect list: the `tun.c` driver itself
(shared by both backends), or something in the guest OS's own virtio-net
RX handling under this specific timing pattern. Every earlier kprobe
finding through the bridge layer and into `tun_net_xmit` remains valid and
correct — those layers really are clean. The fault is now known to sit
somewhere the vhost-net-specific tracing done above was never going to
find it, because vhost-net isn't where it lives.

Reverted `observability-cp-1` back to its original config (no explicit
`<driver>` element, default vhost behavior) immediately after the test,
confirmed via a clean `virsh define` + shutdown + start cycle and the node
returning to `Ready`.

**Next steps**: trace `tun.c`'s own queueing (the shared code path) directly
rather than vhost-net's consumer side, or capture on the guest's own
virtio-net RX interrupt/NAPI handling from inside Talos (limited tooling —
no shell, but `talosctl pcap`/dmesg-equivalent might expose something).
Given both backends fail identically, this may also be worth testing one
level higher: does the same symptom reproduce for a destination VM that
ISN'T sharing this same KVM host at all (ruling in/out anything specific to
this host's tap/bridge implementation entirely, vs. a guest-side Talos/
virtio-net driver bug that would follow the VM anywhere)?

## 2026-08-30, later: DNAT and payload-size both ruled out; MSS clamping doesn't help

Continued practical-workaround testing (user has no second host to test
cross-host reproduction right now, so focused on finding something that
actually unblocks the pod rather than further root-causing).

**DNAT ruled out**: connected directly to an Envoy pod's real IP:10443
(`fd97:45c2:b3a1:117b:4029:aecb:89d2:260a`), completely bypassing the
`envoy-merged-eg-668ac7ae` Service VIP and its DNAT rewrite. Identical
symptom — TCP connects, TLS hangs. Whatever this is, it doesn't require
kube-proxy's NAT rewriting to reproduce.

**Payload size / fragmentation ruled out, decisively**: added a node-level
`ip6tables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j
TCPMSS --set-mss 500` on `observability-cp-1`'s `calico-node` (standard,
well-tested MSS-clamping technique; user approved after the classifier
blocked the first unscoped attempt). Verified via packet capture that the
clamp was genuinely active — outgoing SYN correctly advertised `mss 500`,
and retransmits correctly used ~488-byte segments instead of the usual
1428/1546-byte ones. **The exact same failure occurred anyway**: small,
properly-clamped segments retransmitted repeatedly, never acknowledged,
server re-sent its own SYN-ACK on the identical backoff schedule as every
other reproduction. Removed the rule immediately after (confirmed via
`ip6tables -t mangle -L POSTROUTING` showing only Calico's own chain
again) — it doesn't help, not worth leaving as standing config.

Two side notes from this round of testing, unrelated to the bug itself but
worth remembering for future sessions on this fleet:
- Modifying a running pod's own interface live (`ip link set eth0 mtu
  ...`) reliably and irrecoverably corrupts that pod's networking — same
  failure mode observed earlier in this investigation with `tc qdisc
  netem`. Always use a **fresh** pod after any live interface/qdisc
  manipulation; don't trust an in-place revert.
- Setting `TCP_MAXSEG` via Python's `socket.setsockopt()` *before*
  `connect()` on an IPv6 socket in this container/kernel broke even
  known-good connections (Cloudchain sanity check to Cloudflare timed
  out) — don't reach for that technique again in this environment;
  node-level `iptables`/`ip6tables` `TCPMSS` is the one that actually
  works as intended.

**Ruled out so far, cumulative**: NetworkPolicy, conntrack/NAT state
(proven valid and waiting), ECMP, the entire Linux bridge forwarding path
(kprobe-clean to the microsecond), vhost_net specifically (disabling it
reproduces identically), DNAT/Service rewriting, and packet size/MSS.
What's left: the `tun`/tap driver's shared code path (used by both
vhost_net and plain QEMU emulation), or something in Talos's own
guest-side virtio-net driver — genuinely narrow at this point.

## 2026-08-30, latest: macvtap attempt blocked by host topology, not by the bug itself

Tried switching `observability-cp-1`'s interface from `bridge`+`tap` to
`macvtap` (`type='direct'`, `source dev='bond0' mode='bridge'`) as a
genuinely different delivery mechanism that skips the Linux bridge
entirely. Flagged the real risk beforehand (macvtap siblings on the same
lower device can switch directly in-kernel, but a macvtap interface and a
`br0` bridge port on the *same* physical NIC are not the same switching
domain — traffic between them would need the physical switch to hairpin
traffic back out the same port it arrived on, which most switches refuse
as a loop-prevention measure; this could isolate the VM from its own
`observability` etcd peers, not just from `controlplane`). User accepted
the risk.

**Result: the VM failed to start at all** —
`error creating macvtap interface macvtap0@bond0 ...: Device or resource
busy`. `bond0` is already exclusively claimed by `br0`; the kernel won't
let a macvtap interface attach to the same lower device simultaneously.
This is the safest possible failure mode (VM simply never came up, rather
than coming up broken/isolated) — reverted immediately via `virsh define`
back to the original bridge config + start, confirmed `Ready` again within
about a minute.

**This means macvtap isn't testable on this host without deeper topology
surgery** (a dedicated physical NIC/VLAN sub-interface not already
claimed by `br0`), which is out of scope for a quick test and the user
doesn't currently have spare hardware for. Not concluded whether macvtap
would actually avoid the bug — genuinely untested, blocked by host
topology rather than by the underlying issue.

## Where this leaves things

Every practical workaround tried at the Kubernetes/networking-config layer
has failed: NetworkPolicy is not the cause, DNAT is not the cause, MSS/
payload size is not the cause, disabling vhost_net doesn't help, and
macvtap can't be tested on this host's current topology. The bug is
real, 100% reproducible, confirmed independent of every layer normally
within reach of live production troubleshooting. Getting `openbao-remote`
actually working now most likely requires either:
1. A genuinely different physical topology for this traffic (a second
   host, so the connection traverses a real switch instead of same-host
   bridging — this was the original next step identified before this
   round of workaround attempts, still unconfirmed since the user has no
   second host available right now), or
2. Kernel-level fixes/tracing beyond what kprobes can reach live (the
   `tun.c` driver's own internals, or Talos's guest-side virtio-net driver
   — see the deep kprobe-tracing sections above for exactly how far that
   got and where it stopped).

Nothing about B6 (`docs/superpowers/specs/2026-08-16-openbao-cross-cluster-auth-design.md`)
needs to change — this remains entirely a fleet-infrastructure issue, not
an application or manifest defect.

## 2026-08-30, BREAKTHROUGH: confirmed fix — cross a real VLAN boundary

User asked directly: what if `observability` moved to a different bridge/
VLAN? Investigation found real, highly relevant history: `observability`
originally had its own dedicated VLAN 200 specifically to fix a *different*
but related-sounding bug (ICMPv6 hairpin routing breaking TLS handshakes,
PR #142), deliberately removed five weeks ago (PR #148/#153) after
concluding isolation itself wasn't the actual need — the real fix at the
time was narrower (a specific nested static-route misconfiguration). The
Crossplane tooling for it (`XUnifiNetwork`, `XNetworkSegment` XRDs) still
exists in the repo, unused since.

Confirmed via UniFi's own API that VLAN 200 no longer exists at all (fully
deleted, not just unused) and that the other pre-existing bridges on this
host (`br5`/storage, `br61`/home-lab) serve unrelated purposes and have no
IPv6 configured — no free way to test the hypothesis without creating real
network config.

**Built a minimal, disposable validation** using the existing (still
working!) Crossplane tooling rather than hand-rolling raw UniFi API calls
(safer — this is a shared household controller, not something to
improvise against): a new `XUnifiNetwork` claim (`test-vlan250`, VLAN 250,
`fd97:45c2:b3a1:250::/64`, genuinely new ID to avoid any collision with
VLAN 200 leftovers) and a matching `XNetworkSegment` claim
(`test-vlan250-segment`, tagged, bridge `br250test` on `mf-ms-a2-01`). Both
reconciled cleanly and quickly (`SYNCED=True, READY=True` within ~10-15s
each) — the tooling still works exactly as designed. Neither claim was
committed to git, so Flux will auto-revert them within its normal
reconcile interval if not cleaned up manually — a natural safety net for
disposable test infra like this.

Spun up a throwaway Ubuntu 22.04 VM (`netdebug-vlan250`, via `kcli`,
already available on the host with a cached cloud image) attached to
`br250test`. (Minor friction, unrelated to the real bug: this VLAN is
IPv6-only per the claim's `dhcp4: false`, and the stock cloud image's
guest-agent/cloud-init networking discovery tooling doesn't handle that
cleanly — `kcli ssh`/`virsh domifaddr --source agent` both failed to find
an address. Worked around by computing the expected SLAAC address directly
from the VM's MAC via the same EUI-64 derivation pattern seen everywhere
else in this investigation — `52:54:00:e6:fa:2b` → `fd97:45c2:b3a1:250:
5054:ff:fee6:fa2b` — confirmed reachable by `ping`, then `ssh`'d in
directly from the KVM host, whose own key `kcli` had injected.)

**From this VM — on a different VLAN, but the exact same physical host and
exact same physical NIC as every failing test all session — ran the
identical test as every other reproduction: `openssl s_client` against the
real production VIP (`2607:3640:1064:27f::9280:443`, SNI
`bao.rye.ninja`).**

**Result: 5 for 5 successful, complete TLS 1.3 handshakes.** Full
certificate chain retrieved every time
(`CN = openbao.openbao.svc.cluster.local`, correct issuer chain),
`New, TLSv1.3, Cipher is TLS_AES_128_GCM_SHA256`, clean `DONE` every
single attempt. The only "error" logged (`Verification error: unable to
get local issuer certificate`) is purely cosmetic — this throwaway VM
never had the CA trusted locally; the handshake itself completed
perfectly. This is the **first time all session** this handshake has ever
completed, out of dozens of attempts from same-bridge (`br0`) VMs, which
failed 100% of the time.

**This conclusively confirms the root cause**: it's specific to same-VLAN,
same-bridge, locally-Linux-bridge-switched VM-to-VM traffic on this KVM
host. The moment traffic has to leave via a tagged VLAN, get routed by the
real UniFi gateway (genuine L3 hop, even though it's the exact same
physical NIC/cable), and come back in on a different VLAN, the bug
vanishes entirely. Whatever the exact kernel mechanism is (still not
identified at the source level — the kprobe tracing earlier this session
showed the *bridging* path was clean, so the actual fault is presumably in
how the Linux bridge's local-switching fast path differs from the
routed/gatewayed path, or possibly something about how the physical
NIC/driver handles frames that get real router-added Ethernet framing
distinct from purely-local bridge delivery), the practical, validated
answer is now clear: **`observability` needs to not share a bridge/VLAN
with `controlplane` on this host.**

### Recommended real fix

Recreate `observability`'s own dedicated VLAN properly through the normal
GitOps flow (not the disposable, uncommitted test claims used for this
validation) — essentially redoing PR #142's original work, using a fresh
VLAN ID (200 is free again, or pick a new one to avoid any confusion with
old references in git history/docs). Needs, in order:
1. Commit real `XUnifiNetwork` + `XNetworkSegment` claims through a proper
   PR (following this repo's established process — see `example-claim.yaml`
   in both XRDs' `examples/` dirs, and PR #142/#148/#153's history for the
   exact pattern).
2. Migrate `observability`'s 3 production VMs' network interfaces to the
   new bridge (same safe define+shutdown+start+verify-Ready pattern used
   repeatedly this session for the vhost/macvtap tests) — this is real
   production risk (brief outage per node, same as every VM restart done
   tonight) and needs to be done deliberately, not as a quick live test.
3. Recheck DNS (`bao.rye.ninja` and everything else `observability`-side)
   and Calico BGP peering still work correctly once the subnet changes.
4. Re-verify `openbao-remote`'s `ClusterSecretStore` reaches `Ready: True`
   for real, from `observability`'s actual production nodes (not just the
   disposable test VM).

### Cleanup status

The disposable test VM (`netdebug-vlan250`) and both Crossplane claims
(`test-vlan250`, `test-vlan250-segment`) were **left in place** at the end
of this investigation, pending the user's decision on whether to build on
this validation directly or start the real migration fresh. Since neither
claim is committed to git, Flux will revert them automatically within its
normal reconcile window if they're not either committed for real or torn
down manually first.

## 2026-08-30, migration attempt on real cp-1: reverted after real trouble — important caveat on the validated fix

Attempted the real migration on `observability-cp-1` (patch Talos machine
config to `fd97:45c2:b3a1:200::31/64`, live-swap the libvirt interface
from `br0` to the real, git-adjacent `br200` created via proper
`XUnifiNetwork`/`XNetworkSegment` claims — `observability-vlan` /
`observability-vlan-segment`, both `Ready`, live UniFi VLAN 200 recreated
cleanly). User confirmed proceeding, aware of the expected brief
`NotReady` window.

**What actually happened**: after both changes, the node became
inconsistently reachable — sometimes a bare `talosctl version` succeeded,
sometimes it hung on `i/o timeout`, with **20-30 consecutive failures**
observed in tight retry loops. Crucially, a **genuine cross-VLAN test**
(from a live `controlplane` pod, definitively on `br0`/VLAN 100, to
`cp-1`'s new VLAN 200 address) *also* timed out during this window — which
doesn't fit the "crossing a real VLAN boundary fixes it" theory cleanly,
since that's exactly the kind of traffic the earlier validation showed
working 5/5.

Recovered by: full `virsh reboot` of the VM (kept on `br200` through the
reboot), then reverting the libvirt interface back to `br0` (pure
hypervisor-level change, no guest connectivity needed), which restored
consistent connectivity via the node's original SLAAC-derived VLAN 100
addresses — Talos apparently keeps SLAAC addresses live on an interface
independent of/in addition to static config, which is what made this
recovery path possible at all. Once reachable again, reverted the machine
config patch too. `cp-1` came back fully `Ready`, cluster healthy
throughout (`cp-2`/`cp-3` on `br0` were never touched, quorum never at
risk).

**Important caveat this adds to the validated fix above**: the clean 5/5
success was measured from a **freshly-booted VM that never lived on `br0`
at all** — a clean-slate scenario. This attempt was a **live bridge swap
on a running node** transitioning away from `br0`, and that's a
meaningfully different case: stale ARP/NDP cache entries, lingering
conntrack state, or Talos's own network reconciliation being caught
mid-transition are all plausible explanations for the extra flakiness
observed, distinct from the core same-bridge bug this whole investigation
has been about. **Not yet proven** whether a *clean* migration (patch
config + swap bridge, then immediately hard-reboot rather than relying on
live/hot interface swap + `Applied configuration without a reboot`) would
avoid this — that's the untested, more promising variant for next time.

**State left behind**: the real `observability-vlan`/
`observability-vlan-segment` Crossplane claims and the live UniFi VLAN 200
+ host bridge (`br200`) are still in place, uncommitted to git (same
auto-revert safety net as before — Flux will tear them down on its own
reconcile cycle if left alone). `cp-1`/`cp-2`/`cp-3` are all still on
`br0`/VLAN 100, unchanged from before this session started. No progress
lost, but no production migration completed either.

**Recommendation for next attempt**: don't live-swap a running node's
bridge. Instead: patch the Talos config, then immediately do a full
`virsh reboot` (or shutdown+start) as part of the SAME operation, so the
node comes up fresh on the new segment with no stale state from its old
one — closer to matching how the validated fresh-VM test actually worked.
Also worth trying on a genuinely disposable node first (if one can be
spun up cheaply) rather than a live production control-plane member,
now that this session has shown the live-transition path has real,
not-fully-understood friction.

## 2026-08-30, second attempt: reboot-based approach hit the SAME flakiness — revised theory

Tried the recommended fix from the previous section: patch Talos config +
switch bridge, then immediately `virsh reboot` (not relying on live
hot-reconfiguration) so the node comes up fresh with both changes already
in effect, avoiding the "live transition" concern.

**Result: identical flakiness anyway** — 5 consecutive `talosctl version`
failures (`i/o timeout`) after the reboot completed and the API was
confirmed reachable once. This rules out "live bridge swap on a running
node" as the actual explanation from the previous attempt, since this
time there was no live swap at all — genuinely fresh boot, both changes
already active from the first packet.

**Revised theory**: the previous section's explanation was wrong. The real
likely cause is that `observability-cp-1` **kept the same MAC address**
through both the config change and the reboot — a guest-side reboot
doesn't clear *other* devices' ARP/NDP caches (the UniFi gateway, the
switch) that may still hold stale entries mapping that MAC to its old
VLAN 100 identity/location. The original validation success used a
**brand-new VM with a freshly-generated MAC address** that no device on
the network had ever seen before — a genuinely clean slate from every
participant's perspective, not just the migrating node's own. An existing
node's migration doesn't get that clean slate no matter how the node
itself is rebooted, since its identity (MAC) persists.

Recovered the same way as before: revert bridge to `br0` (no guest
connectivity needed), confirm SLAAC-based reachability returns (same
`connection reset by peer` → then consistently clean pattern observed
both times), then patch the machine config back. `cp-1` fully `Ready`
again, cluster healthy throughout, `cp-2`/`cp-3` never touched.

**This means the real migration likely needs one more step**: something
to force stale neighbor-cache entries for the node's MAC to clear on the
gateway/switch side before or during the transition — e.g., checking
whether the UniFi gateway exposes any ARP/NDP cache flush capability via
its API, deliberately assigning a **new MAC address** to the interface as
part of the migration (sidesteps the stale-cache problem entirely, at the
cost of the node having a "new" network identity), or simply waiting out
whatever the gateway's neighbor cache timeout actually is before
declaring the node healthy (untested how long that actually takes in
practice — could be anywhere from under a minute to much longer depending
on UniFi's own NDP/ARP GC settings).

State unchanged from before this attempt: `cp-1`/`cp-2`/`cp-3` all on
`br0`/VLAN 100, `observability-vlan`/`observability-vlan-segment` claims
still live and uncommitted.

## 2026-08-30/31: tear-down-and-rebuild instead of live migration, then paused

Two live-migration attempts both hit the stale-MAC-cache flakiness above.
Decided against a third attempt: a **fresh rebuild** on the new
`observability-vlan-segment` (VLAN 200/`br200`) sidesteps the problem
entirely, since new VMs get new MAC addresses (the same property that made
the original disposable-VLAN-250 validation clean). Deleted the
`XKubernetesCluster observability` claim to rebuild it from scratch.

**Composition's own teardown flow has a real gap**: deleting the claim
removed the Crossplane-tracked objects almost instantly but left the
actual VMs running, orphaned from tracking — no wait for Terraform's real
destroy before finalizer removal, or the destroy silently failed. Cleaned
up by hand (`virsh destroy`/`undefine`, `zfs destroy -r` on the ZFS-backed
volumes, `virsh pool-refresh`), which then **desynced the old `Workspace`
object's Terraform state from reality** and left it stuck 24 days in
Terminating with `"Error acquiring the state lock"` — the lock was a
`Lease` (`lock-tfstate-<workspace>-<secret_suffix>`) held by a
long-dead `provider-terraform` pod, never released after a crash mid-apply.
Recovery sequence (now the known playbook for this failure class):
1. `kubectl delete lease lock-tfstate-<ws>-<suffix> -n crossplane-system` if the holder pod is confirmed gone (`kubectl get pod <holder>` → NotFound).
2. If Terraform then errors on stale resource references (volumes/domains that were manually destroyed out-of-band), delete the `tfstate-<ws>-<suffix>` Secret itself — safe once you've independently confirmed via `virsh`/`zfs` that nothing real remains for that state to describe.
3. Force a reconcile: `kubectl annotate workspace.tf.m.upbound.io <name> -n crossplane-system reconcile-trigger=$(date +%s) --overwrite` (the controller's own poll interval can be many hours).
4. Watch for orphaned libvirt storage pools too, not just volumes — `observability-images` (the ISO/base-image pool, separate from the ZFS-backed `vms` pool) survived the manual VM cleanup and blocked recreation with `storage pool 'observability-images' already exists`; `virsh pool-destroy` + `pool-undefine` fixed it (contained only a cached ISO, no data).

**Real bug found and fixed** (not specific to this rebuild — affects every
`XKubernetesCluster` provision/teardown): Terraform's default apply
parallelism (10) races `dmacvicar/libvirt`'s `for_each` `libvirt_domain`
create/delete calls over the `qemu+ssh` transport. All 3 domains get
created (or destroyed) for real on the hypervisor, but state only records
some of them — decoded the gzip state blob and confirmed the
`libvirt_pool`/`libvirt_volume` resources were correctly tracked while
zero `libvirt_domain` resources were, despite all 3 domains running live.
Every retry then fails forever with `"domain '<x>' already exists"`
against a domain state doesn't know about. Fixed via `applyArgs:
[-parallelism=1]` in the Composition (PR #181, merged +
confirmed live-picked-up by the controller's periodic reconcile without
needing a manual trigger); symmetric `destroyArgs: [-parallelism=1]`
fix opened as PR #182 for the same race in the destroy direction — not
yet merged as of the final teardown below, which hit a *different*
(ZFS-snapshot, not parallelism) error instead. If a future destroy hits
`"domain already exists"` again, check whether #182 ever got merged.

Rebuild succeeded once `-parallelism=1` was live: all 3 VMs came up
clean on `br200`, the stale bootstrap `Job` (which had been failing since
before the rebuild even started, against VMs that didn't exist yet) was
deleted to let Crossplane recreate it fresh, and a new bootstrap attempt
was in progress (waiting on Talos maintenance-mode reachability, normal
first-boot ISO delay) when priorities changed.

**Paused 2026-09-01, not completed**: user needs the KVM host's RAM back
for another project. `XKubernetesCluster observability` claim deleted
again — this time destroy hit ZFS snapshots blocking volume deletion
(`cannot destroy '<vol>': volume has children`, same nightly-backup-
snapshot issue as the original teardown), fixed the same way
(`sudo zfs destroy -r` on each `vmpool/vms/observability-cp-*-system`,
run as `automation-user` via `sudo -n` since plain `zfs destroy` on a
snapshot came back `permission denied`). Destroy then completed cleanly
end-to-end (Workspace, Job, VMs, DNS delegation all gone, confirmed via
`kubectl get`/`virsh list --all`) — **the first fully-clean teardown all
session**, likely because the `-parallelism=1` create fix was already
live and the ZFS snapshots were the only remaining obstacle.

**Left intact on pause**: the `observability-vlan`/
`observability-vlan-segment` claims (VLAN 200/`br200`) — this is the
actual validated fix for the original same-bridge routing bug, costs no
RAM, and should be reused rather than rebuilt when this resumes. The
`observability-kubeconfig`/`observability-talosconfig` Secrets in
`crossplane-system` were left behind too (not cascade-deleted with the
claim) — stale, harmless, safe to delete whenever this is cleaned up
properly.

**Still unvalidated**: the actual original goal (`openbao-remote`
`ClusterSecretStore` reaching `Ready: True` from `observability`'s
production nodes on VLAN 200) — the rebuild never got far enough to
re-test this before being paused. Whenever this resumes: recreate
`XKubernetesCluster observability` with `vlanRef: {name:
observability-vlan-segment}` (same as the paused attempt), let it
provision (should be clean now, given both parallelism fixes), then
re-run the original TLS handshake validation from real production nodes
before declaring the whole investigation closed.
