---
name: pinniped-apiservice-discovery-failure
description: v1alpha1.clientsecret.supervisor.pinniped.dev APIService has been FailedDiscoveryCheck for 17+ days on controlplane, stalling namespace-termination sweeps cluster-wide
metadata:
  type: project
---

Found 2026-08-11 while debugging why a chainsaw suite's own auto-created,
empty ephemeral namespace hung past its cleanup timeout (`context deadline
exceeded`) on `controlplane` — nothing to do with the suite's own resources.

`kubectl get ns <stuck-ns> -o yaml` showed
`NamespaceDeletionDiscoveryFailure: unable to retrieve the complete list of
server APIs: clientsecret.supervisor.pinniped.dev/v1alpha1: stale
GroupVersion discovery`, despite `ContentRemoved`/`ContentHasNoFinalizers`
both being true — the namespace controller's discovery check itself is what
stalls, not anything about the namespace's actual content.

`kubectl get apiservices` confirms: `v1alpha1.clientsecret.supervisor.pinniped.dev`
(backed by `pinniped-supervisor/pinniped-supervisor-api`) has been
`False (FailedDiscoveryCheck)` for **17d** — a real, longstanding,
pre-existing issue, not something this session's changes caused. Every other
Pinniped APIService (concierge auth/config/identity/login, supervisor
config/idp) is healthy; only this one clientsecret group is affected.

**Why this matters**: any future chainsaw suite (or anything else) that
creates and deletes a Kubernetes `Namespace` on `controlplane` may hit slow
or stalled namespace termination until this is fixed — not a suite-specific
bug, don't waste time debugging the suite itself first.

**Not yet investigated further** (out of scope for M4 step 6, where this was
found) — worth a look next time someone's touching Pinniped Supervisor:
whether `pinniped-supervisor-api`'s Service/Deployment is actually unhealthy,
or the APIService's CA bundle is stale, or something else. Flagging, not
fixing — priority is the user's call ([[feedback-urgency-is-users-call]]).

**Workaround used, not a fix**: chainsaw suites whose own resources don't
live in chainsaw's default ephemeral namespace can set
`spec.namespace.fastDelete: true` in their `.chainsaw.yaml` `Configuration`
to skip waiting on that namespace's deletion outcome entirely (see
`tests/xkubernetescluster-validation/.chainsaw.yaml`).

**Also blocks plain resource-finalizer cleanup, not just Namespace
termination**: while live-verifying the `Usage`/`ClusterUsage` API for M4
step 6's Usage guards, two scratch resources got stuck `Terminating` the
same way — `namespace/chainsaw-scratch-cluster-of` and
`usage.protection.crossplane.io/chainsaw-scratch-ns-usage` (both in/under
`crossplane-system` on `controlplane`) — their own finalizer-removal
controllers appear to stall on the same discovery failure. Harmless orphans
(the Usage never had any real protective effect — it was the scratch
resource that proved cluster-scoped `of` targets aren't enforced, see
[[m4-step-tracker]]), left in place rather than forced, since force-deleting
finalized-but-stuck resources risks masking the real bug instead of fixing
it. Clean up both once the underlying APIService issue is resolved.
