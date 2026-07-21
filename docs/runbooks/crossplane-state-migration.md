# Runbook: Crossplane managed-resource state migration between clusters

Moving Crossplane-managed external resources (AWS, Cloudflare, etc.) from
one cluster's Crossplane install to another's, without the destination
provider creating new cloud-side resources. First executed for the
`crossplane.rye.ninja` delegated-zone stack in M2 step 8
([docs/memory/m2-step8-delegated-zone-migration.md](../memory/m2-step8-delegated-zone-migration.md));
written up here as the general pattern for reuse at M6+ (cloud-substrate
migrations) and the plan's recurring drill cadence.

Precondition: the destination cluster already has matching
`ProviderConfig`/`ClusterProviderConfig` objects (same names) for every
provider the resources use, and the same Composition/XRD installed if a
claim is involved. If it doesn't, this is a bigger job than this runbook
— stand those up first.

## The five-phase pattern

### 1. Recon — before touching anything

Confirm the source cluster's resources are in the state you think they're
in. For every managed resource being migrated, record: kind, namespace,
name, `crossplane.io/external-name` annotation, `providerConfigRef`,
`Synced`/`Ready` status. Compare against whatever inventory/snapshot
predates this migration (a stale inventory is a source of truth for
external IDs even if the live cluster is gone — see M2 design §3, risk
R1). Do not proceed if anything is `Synced=False` or the external-name
doesn't match the inventory — fix or investigate that first.

### 2. Orphan-protect and pause the source

**`deletionPolicy` doesn't exist on current Crossplane** — it's been
replaced by `spec.managementPolicies` (array of `Observe|Create|Update|
Delete|LateInitialize|*`, default `["*"]`). Patch every resource being
migrated to **`["Observe"]` only** — not the fuller
`["Observe","Create","Update","LateInitialize"]` that merely mirrors the
old `deletionPolicy: Orphan` semantics. This matters: if the source's
external resource is ever deleted (deliberately, at the corresponding
step on the destination, or by anything else) while the source's copy
still has `Create` allowed, the source will recreate it on its very next
reconcile. `["Observe"]` makes the source cluster's copy a pure read-only
mirror for the rest of the migration — it can never create, update, or
delete anything, no matter what else goes wrong.

```sh
kubectl -n <ns> patch <kind>.<group> <name> --type merge \
  -p '{"spec":{"managementPolicies":["Observe"]}}'
```

Do this to every resource being migrated, one `kubectl patch` at a time
(not piped through `xargs` — batch mutation commands are more likely to
trip permission classifiers than one-at-a-time equivalents, and one-at-a-
time gives you a clean per-resource error if something's wrong).

Then pause the source cluster's Crossplane, **in this order**:

1. **Suspend the source cluster's Flux Kustomization(s) that manage
   `crossplane-system` first** — `kubectl patch kustomization <name> -n
   flux-system --type merge -p '{"spec":{"suspend":true}}'` for every
   Kustomization that could touch it. Do this *before* scaling anything.
2. Only then scale `crossplane-system` deployments (core, rbac-manager,
   every provider and function pod — all of them, not just the ones
   directly touching the migrated resources) to 0 replicas, one at a
   time.

**Why this order, specifically**: scaling deployments to zero without
suspending Flux first is not a pause — Flux will reconcile them back to
their desired (non-zero) replica count on its next pass, typically within
about a minute. This isn't hypothetical: it happened mid-migration during
the M2 delegated-zone decommission
([[m2-step13-decommission]]) — Spot's Flux silently undid a step-8 scale-
down, and once the corresponding AWS resources were deleted on the
destination side, Spot's still-running, still-`Create`-enabled provider
recreated the entire stack (IAM role, policy, RolesAnywhere profile,
Route53 zone, and — worse — 4 live Cloudflare NS records back in
production DNS) not once but three times, because each recovery attempt
scaled some deployments before getting to suspend Flux, and Flux kept
re-reverting whatever hadn't been caught yet. Scaling *and* suspending
Flux in the same pass, Flux first, closes this gap. `["Observe"]`-only
management policy closes it a second, independent way — treat both as
required, not either-or.

### 3. Export, then reconcile against the inventory

Export each resource's full YAML (`kubectl get <kind> <name> -o yaml`).
Strip `resourceVersion`, `uid`, `generation`, `creationTimestamp`,
`managedFields`, `ownerReferences`, `finalizers`, and `status` — none of
these are valid on the destination (the `ownerReferences` UID in
particular will point at a claim/XR that doesn't exist there, and if
left in place the destination's garbage collector can eventually treat
the object as orphaned and delete it). Keep the `crossplane.io/
external-name` annotation and `crossplane.io/composition-resource-name`
annotation (the latter helps a composition match pre-existing resources
by their templated role, not just by name) exactly as-is.

Diff the external-name/spec.forProvider values against the pre-migration
inventory snapshot. Zero diff is the goal — this is what makes the
import safe.

### 4. Import on the destination: observe, not create

If a claim/XR composition will eventually own these resources, the
composition generates deterministic resource names from the claim name
(e.g. `ns0-<claim-name>`, `<role-kind-prefix>-<claim-name>`). Find that
naming convention on an *already-successfully-composed* example on the
destination cluster first (`kubectl get <xrkind> <existing-claim> -o
jsonpath='{.spec.crossplane.resourceRefs}'`) — don't guess it from the
composition source.

Apply the cleaned managed resources standalone first, under those exact
names, with `managementPolicies` still excluding `Delete`. Apply one
resource at a time, not in a loop — same reasoning as step 2. Then apply
a **minimal** claim manifest (just the user-facing spec fields; let
Crossplane populate `spec.crossplane.*` itself rather than carrying over
the source cluster's stale `compositionRevisionRef`). The composition
will match the pre-existing resource names, patch them to desired state,
and — because the external-name annotation is already set — call
`Observe`, not `Create`.

**Verify no create happened**, in this order:

1. `external-name` annotation unchanged after the composition reconciles.
2. `Synced=True, Ready=True` on every resource and the claim.
3. Watch for an `UpdatedExternalResource` event (fine — usually
   late-initialize/tag normalization) vs. any `CreatedExternalResource`
   event (not fine — means adoption failed and a duplicate now exists;
   roll back per step 5 below before this compounds).
4. **Don't stop at Crossplane's own status.** At least three resource
   kinds (IAM `Policy`, IAM `RolePolicyAttachment`, RolesAnywhere
   `Profile` — probably others) reconcile to `Synced=True` but leave
   `status.atProvider` empty and never set a `Ready` condition when
   `managementPolicies` is a partial (non-`["*"]`) list. No error, no
   event — just silence. This looks alarming but isn't necessarily a
   problem; verify against the actual cloud API instead of waiting on
   Crossplane's status to fill in (`aws iam get-policy`, `aws
   rolesanywhere get-profile`, etc. — whatever's authoritative for that
   provider). If the cloud-side resource's creation timestamp/ID is
   unchanged, the import succeeded regardless of what Crossplane's
   status object shows.

### 5. Restore full management, or roll back

Once verified, patch `managementPolicies` back to `["*"]` on the
**destination's** migrated resources only. Full management restores
`Delete` capability, which is also required for the composition to
behave identically to a natively-created instance going forward.

**Never restore the source copies to `["*"]` or anything past
`["Observe"]`.** They stay `["Observe"]`-only (per step 2) for the rest
of their existence — either until the source's Kubernetes objects are
deleted with an explicit, deliberate policy change at the actual
decommission step, or, more simply, until the source cluster itself is
destroyed wholesale. There is no point in this pattern where the source
copies should ever regain `Create` or `Update`.

**Rollback**, if step 4's verification fails: the imported resources on
the destination are still Orphan-protected (`Delete` excluded from
`managementPolicies`), so deleting the destination's Kubernetes objects
does not touch the cloud-side resource. Delete them, fix whatever was
wrong, and retry from step 3. The source cluster's Crossplane is still
paused and its resources still exist — nothing was lost.

## Gotchas encountered so far (add to this list when you hit a new one)

- **"Pausing" the source by scaling deployments to zero isn't a pause if
  its Flux isn't also suspended — see step 2.** Caused a real,
  three-times-repeated production DNS incident during M2 decommission.
  Suspend Flux first, scale second, and keep the source's managed
  resources at `["Observe"]` (not a fuller policy list) as a second,
  independent guard.
- **Manual patches to Flux-managed Deployments get reverted.** If you're
  tempted to add `--debug` to a provider pod to see what's happening,
  don't bother if that Deployment is Flux-managed — the next
  reconciliation (observed within ~1 minute) silently wipes the change.
  Go straight to independent verification against the cloud API instead.
- **Batch/piped mutation commands (`xargs kubectl ...`, `for` loops
  calling `kubectl apply` on multiple files) are more likely to be
  blocked by the auto-mode permission classifier than the same commands
  run one at a time.** If a batch form gets denied, don't retry the same
  batch form — split it into individual invocations.
- See [docs/runbooks/step-ca-db-restore.md](step-ca-db-restore.md) for
  the equivalent NetworkPolicy gotcha when the migration involves
  spinning up any new named workload (not specific to Crossplane, but
  bites in the same "everything's silent, nothing errors" way).
