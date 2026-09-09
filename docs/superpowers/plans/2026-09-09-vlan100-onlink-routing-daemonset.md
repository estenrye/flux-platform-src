# Fix VLAN-100-resident client on-link reply drops via policy-routing DaemonSet

> **For agentic workers:** this plan follows the Flux GitOps workflow used
> throughout this investigation — open a PR against `flux-platform-src`,
> merge, wait for the render workflow to create/update the corresponding
> PR in `flux-platform-rendered-controlplane`, merge that too (auto-merge
> is deliberately disabled there —
> [docs/memory/rendered-repo-automerge-milestone.md](../../memory/rendered-repo-automerge-milestone.md)
> — merge by hand), then force a Flux reconcile
> (`kubectl -n flux-system annotate gitrepository/kustomization
> reconcile.fluxcd.io/requestedAt=$(date +%s) --overwrite`) rather than
> waiting for the interval. Read the spec first:
> [2026-09-09-vlan100-onlink-routing-daemonset-design.md](../specs/2026-09-09-vlan100-onlink-routing-daemonset-design.md).
>
> **Task 1 is a hard gate.** Do not proceed to Task 2 (building any
> permanent resource) unless Task 1's manual validation shows a clean,
> repeated pass with no cluster-health regression. If it fails or is
> inconclusive, stop and re-scope — do not "try building it anyway to see."

**Goal:** Confirm, then permanently fix, the on-link-reply-drop bug that
breaks any VLAN-100-resident client's connection to a `controlplane`
Gateway-fronted service — root-caused to Talos nodes' `ens3` treating both
VLAN 100 prefixes (`fd97:45c2:b3a1:100::/64` ULA,
`2607:3640:1064:270::/64` GUA) as on-link, replying via direct NDP instead
of routing, with something in that path silently dropping the connection
mid-flow. Unblocks the pending VLAN 179 final cutover and Designate's
`usmnblm01.rye.ninja` zone creation.

**Architecture:** 6 Talos Linux VMs (`controlplane-cp-1/2/3`,
`controlplane-wk-1/2/3`) on KVM (`mf-ms-a2-01`), Calico (BGP mode),
Flux-managed `controlplane` cluster. Real VLAN-100-resident test clients:
`mf-ms-a2-01` (the KVM host itself) and `pcd-ce-hyp-01`
(`10.45.60.1`, reachable via `ssh -J mf-ms-a2-01.usmnblm01.rye.ninja
automation-user@10.45.60.1`, username `automation-user`).

**Tech stack:** `iproute2` (policy routing: custom table + `ip -6 rule`),
Kubernetes `DaemonSet` + `ClusterRole`/`ClusterRoleBinding` (Node API
read access for dynamic peer discovery), `talosctl`/`kubectl` for
validation, Flux (Kustomize rendering).

## Key Facts

- **Root cause, confirmed live 2026-09-08/09**: `ens3` on every Talos
  node carries connected routes for both VLAN 100 prefixes (SLAAC/RA).
  Any destination in either is on-link; the node's reply bypasses routing
  via direct NDP, and something in that path silently drops the
  connection mid-flow (exact mechanism — conntrack, driver offload,
  gateway-side — still unconfirmed).
- **Not GUA-specific** (corrects an earlier 2026-09-09 conclusion): a
  ULA-internal VIP built specifically to avoid the GUA prefix
  (`applications/envoy-gateway/base/resources/internal-proxy-config.envoyproxy.yaml`,
  PRs #189-191) hit the identical failure against `pcd-ce-hyp-01`, a
  genuinely VLAN-100-resident client. The real discriminator is VLAN-100
  residency, not address family — no VIP relocation can fix this.
- **Known node addresses** (ULA, VLAN 100 — from `kubectl get nodes -o
  wide`): `cp-1` `fd97:45c2:b3a1:100::11`, `cp-2` `::12`, `cp-3` `::13`,
  `wk-1` `::21`, `wk-2` `::22`, `wk-3` `::23`. Gateway link-local:
  `fe80::ae8b:a9ff:fe6e:13de` (interface `ens3` on every node).
- **`wk-2` runs close to CPU capacity** (found live 2026-09-09, ~97%
  requested) — be mindful of it when choosing a pilot node or scheduling
  anything new; prefer `cp-1`, `cp-3`, `wk-1`, or `wk-3` for the pilot.
- **Reproduction/verification methodology already proven this session**:
  `curl -6 --max-time 8 https://pdns4-shim.rye.ninja/healthz` from
  `pcd-ce-hyp-01` (via the `mf-ms-a2-01` jump host), correlated with
  `tcpdump -i ens3` on whichever node is handling the flow, via a
  throwaway `hostNetwork: true` `nicolaka/netshoot` debug pod in a
  dedicated namespace labeled `pod-security.kubernetes.io/enforce:
  privileged` (delete the namespace when done — do not relabel `default`
  or any shared namespace). Reuse this exact methodology.
- **Highest risk**: forcing the reply through the gateway could
  reintroduce ADR-22's hairpin bug for this traffic pattern instead of
  fixing anything — validate before building (Task 1).
- **Cluster-health check discipline**: because the peer-exception scoping
  (Task 1/2) directly touches routes that etcd/kubelet/Calico's BGP mesh
  depend on, every step that changes live routing must be immediately
  followed by a cluster health check (`kubectl get nodes`, `kubectl get
  pods -n kube-system`/`calico-system` for CrashLoop, `etcdctl
  endpoint health` if accessible) before moving on — a scoping mistake
  here risks a cluster-wide outage, not just this one bug.

## File Map

| File | Action | Description |
|---|---|---|
| `applications/vlan100-onlink-routing-fix/base/catalog.yaml` | Create | App catalog entry (Task 2+, only after Task 1 gate passes) |
| `applications/vlan100-onlink-routing-fix/base/kustomization.yaml` | Create | Standard app kustomization |
| `applications/vlan100-onlink-routing-fix/base/resources/rbac.yaml` | Create | `ServiceAccount` + `ClusterRole` (`get`/`list`/`watch` on `nodes`) + `ClusterRoleBinding` |
| `applications/vlan100-onlink-routing-fix/base/resources/configmap.yaml` | Create | The reconcile script (idempotent table/rule setup + Node-API peer discovery) |
| `applications/vlan100-onlink-routing-fix/base/resources/daemonset.yaml` | Create | The `DaemonSet` itself — `hostNetwork`, `NET_ADMIN`, control-plane toleration |
| `applications/vlan100-onlink-routing-fix/controlplane/kustomization.yaml` | Create | Cluster-specific overlay (this fix is `controlplane`-only) |
| `docs/memory/node-gua-onlink-reply-unreliable.md` | Modify | Record the validation result and, if it works, the closing update |
| `docs/adr/0028-vlan100-onlink-routing-daemonset.md` | Create (Task 6, only if Task 1-5 succeed) | New ADR — this is a deliberate, permanent exception to Talos's immutable-host model and deserves its own record, not an amendment to an unrelated ADR |

## Task 1: Manual single-node validation (hard gate — no permanent resources yet)

**Files:** none (temporary debug pod only, deleted after)

- [ ] Pick a pilot node with headroom (`cp-1`, `cp-3`, `wk-1`, or `wk-3` —
      not `wk-2`). Deploy a throwaway `hostNetwork: true`
      `nicolaka/netshoot` pod, privileged, in a fresh dedicated namespace
      (`pod-security.kubernetes.io/enforce: privileged` on that namespace
      only), pinned to the pilot node via `nodeName`.
- [ ] Inside it, hand-run the table + rule setup for that one node only:
      ```
      ip -6 route add fd97:45c2:b3a1:100::/64 via fe80::ae8b:a9ff:fe6e:13de dev ens3 table 100
      ip -6 route add 2607:3640:1064:270::/64 via fe80::ae8b:a9ff:fe6e:13de dev ens3 table 100
      # /128 on-link exceptions for the other 5 nodes' ULA addresses (hardcode for this manual test)
      ip -6 route add fd97:45c2:b3a1:100::11/128 dev ens3 table 100   # (skip if this is the pilot node itself)
      ip -6 route add fd97:45c2:b3a1:100::12/128 dev ens3 table 100
      ip -6 route add fd97:45c2:b3a1:100::13/128 dev ens3 table 100
      ip -6 route add fd97:45c2:b3a1:100::21/128 dev ens3 table 100
      ip -6 route add fd97:45c2:b3a1:100::22/128 dev ens3 table 100
      ip -6 route add fd97:45c2:b3a1:100::23/128 dev ens3 table 100
      ip -6 rule add to fd97:45c2:b3a1:100::/64 lookup 100 priority 100
      ip -6 rule add to 2607:3640:1064:270::/64 lookup 100 priority 100
      ```
- [ ] **Immediately** check cluster health from a separate shell: `kubectl
      get nodes`, `kubectl get pods -n kube-system -n calico-system` for
      new CrashLoops, confirm the pilot node stays `Ready` and etcd/Calico
      BGP mesh sessions to it stay up. **If anything regresses, revert
      immediately** (`ip -6 rule del ...` / delete the debug pod) and stop
      — do not proceed further on this design.
- [ ] Force the ECMP-selected node for a test request to be the pilot node
      (temporarily scale other `internal-eg` replicas to 0, or repeat
      attempts until one lands there — same trial-and-error approach used
      earlier this session) and re-run the proven reproduction: `curl -6
      --max-time 8 https://pdns4-shim.rye.ninja/healthz` from
      `pcd-ce-hyp-01`, 5+ consecutive attempts landing on the pilot node.
- [ ] **Gate**: only proceed to Task 2 if this shows a sustained,
      repeated 100% success rate with zero cluster-health impact. If it
      fails, or only partially helps, stop — update the spec/memory with
      the result and re-scope (see spec §4, "if it doesn't work").
- [ ] Clean up: revert the `ip rule`/`ip route` changes, delete the debug
      pod and its namespace, restore any temporarily-scaled replicas.

## Task 2: Scaffold the DaemonSet application (only if Task 1 passed)

**Files:** `applications/vlan100-onlink-routing-fix/**`

- [ ] `base/resources/rbac.yaml`: `ServiceAccount`, `ClusterRole`
      (`apiGroups: [""]`, `resources: ["nodes"]`, `verbs: ["get", "list",
      "watch"]` — nothing else), `ClusterRoleBinding`.
- [ ] `base/resources/configmap.yaml`: the reconcile script — queries
      `https://kubernetes.default.svc/api/v1/nodes` (bearer token + CA
      cert from the projected `ServiceAccount` volume) for
      `.status.addresses[type=InternalIP]`, builds table `100` and the
      two `ip rule`s idempotently (`ip route replace`, existence checks
      before `ip rule add`), loops on a ~60s interval, and does **not**
      wipe the table on a transient API failure.
- [ ] `base/resources/daemonset.yaml`: `hostNetwork: true`,
      `securityContext.capabilities: [NET_ADMIN]` (not full
      `privileged`), the same control-plane toleration pattern as
      `custom-proxy-config.envoyproxy.yaml`, a minimal image with
      `iproute2` + `curl`/`jq`, mounts the `ConfigMap` script.
      **Scope the initial rollout to the Task 1 pilot node only** via
      `nodeSelector`/`nodeAffinity` — do not go fleet-wide yet.
- [ ] `controlplane/kustomization.yaml`: cluster-specific overlay (this
      fix does not apply to any other cluster).
- [ ] Verify: `kustomize build --enable-helm
      applications/vlan100-onlink-routing-fix/controlplane` renders
      cleanly; `kube-linter` clean.

## Task 3: Pilot the DaemonSet for real (one node, via Flux)

**Files:** none (verification only)

- [ ] PR + merge + render-PR-merge + reconcile, same flow as PRs
      #189-191 earlier this session.
- [ ] Verify the pilot node's pod comes up, applies the same table/rules
      Task 1 validated by hand, and cluster health stays clean
      (`kubectl get nodes`, `calico-system`/`kube-system` pods).
- [ ] Re-run the reproduction against the pilot node (same as Task 1) —
      confirm it still passes through the DaemonSet-managed path, not
      just the earlier hand-run one.

## Task 4: Fleet-wide rollout

**Files:** `applications/vlan100-onlink-routing-fix/base/resources/daemonset.yaml`

- [ ] Remove the pilot-only `nodeSelector`/`nodeAffinity` restriction so
      the `DaemonSet` covers all 6 nodes (keep the control-plane
      toleration).
- [ ] PR + merge + render-PR-merge + reconcile.
- [ ] Verify: all 6 nodes show a `Running`/`Ready` pod for this
      `DaemonSet`; spot-check the routing table/rules on 2-3 more nodes
      beyond the pilot.

## Task 5: Fleet-wide verification

**Files:** none (verification only)

- [ ] Repeated (10+) back-to-back `curl` attempts from `pcd-ce-hyp-01`
      against `pdns4-shim.rye.ninja`, regardless of which node ECMP/the
      Envoy replica selects.
- [ ] Same test from `mf-ms-a2-01` (the original stand-in client) for
      cross-confirmation.
- [ ] Full cluster health sweep: `kubectl get nodes` all `Ready`, no new
      `CrashLoopBackOff`/`NotReady` anywhere, `calico-system` BGP mesh
      sessions all up, etcd healthy.
- [ ] Confirm Designate's own automatic retry loop successfully creates
      the pending `usmnblm01.rye.ninja` zone without manual intervention
      — the original goal that started this entire investigation.

## Task 6: Documentation

**Files:** `docs/memory/node-gua-onlink-reply-unreliable.md`,
`docs/adr/0028-vlan100-onlink-routing-daemonset.md`

- [ ] Update the memory file with the final outcome — root cause
      confirmed/fixed, or, if the design failed validation at Task 1,
      record that clearly so this direction isn't re-attempted blindly.
- [ ] If successful: write ADR-0028 recording this as a deliberate,
      permanent exception to Talos's immutable-host model — what it does,
      why it's needed, and the scoping discipline (peer exceptions,
      `NET_ADMIN` not full `privileged`) that keeps its blast radius
      contained.

## Task 7: Resume the blocked follow-on work

**Files:** none (cross-reference only)

- [ ] Resume [2026-09-08-controlplane-bgp-vlan179.md](2026-09-08-controlplane-bgp-vlan179.md)'s
      Task 9 (remove VLAN 100 from the BGP peer-group — the final
      cutover step that's been blocked on this whole investigation).

## Automatable vs. manual summary

| Step | Automatable | Manual |
|---|---|---|
| Task 1 validation | Partial (scripted `ip`/`curl` commands) | Judgment call on "is this a clean pass," cluster-health monitoring |
| RBAC/DaemonSet/ConfigMap | Yes (git commit + Flux) | — |
| Pilot/fleet rollout | Yes (Flux PR + reconcile) | Pilot-node choice, go/no-go gate |
| Verification | Partial (scriptable `curl` loop) | Cluster-health judgment calls |
| ADR/memory updates | Yes (git commit) | — |
