---
name: m4-step6-tier-b-first-live-run
description: Tier B (real end-to-end XKubernetesCluster provision+teardown) run live 2026-08-15; first attempt blocked by an unrelated sealed-OpenBao incident, second attempt passed cleanly in 155s
metadata:
  type: project
---

M4 step 6's last deferred item — [[m4-step-tracker]] — closed out.

**First attempt failed on an unrelated infrastructure issue, not the
suite itself**: the `xkc-lifecycle-test` claim's VM provisioned fine
(`Workspace: Ready`) and DNS delegation resolved, but the
`talos-cluster-bootstrap` Job failed all 3 attempts (`backoffLimit: 2`)
with `Error writing data to auth/kubernetes/login: ... 503 ... Vault is
sealed`. Both `openbao-0`/`openbao-1` were `0/1 Ready` (sealed) since a
restart ~75-80 min earlier — a real, fleet-wide incident (breaks ESO sync,
Crossplane provider credential refresh, anything reading OpenBao), found
by this run but not caused by it. Stopped the suite before its 20-minute
timeout rather than let it run to a guaranteed failure; deleted the
half-provisioned claim and independently confirmed clean teardown even
from that partial state (no leftover K8s resources, no orphaned VM/pool
on the KVM host) — itself a useful, if accidental, data point for exactly
what this suite exists to prove.

**Second attempt, after the user unsealed OpenBao (`openbao-0`/`openbao-1`
back to `1/1 Ready`), passed end-to-end in 154.90s** — far faster than the
suite README's conservative ~10-20 min estimate:
1. Claim → real VM (Terraform) → Talos bootstrap (Job, now able to reach
   OpenBao) → DNS delegation → `status.phase: Ready`.
2. Composed `Workspace`, bootstrap `Object`, both connection Secrets, and
   both `Usage` guards all present and `Ready`.
3. Confirmed the `Usage` guard denies a real delete of *this* claim's own
   `xkc-lifecycle-test-kubeconfig` Secret (not just `observability`'s,
   already confirmed separately in step 6's PR).
4. Claim deleted → confirmed every Crossplane-owned composed resource gone
   (claim, `Workspace`, bootstrap `Object`, `XDelegatedHostedZoneAWS` +
   its real Route53 zone, both `Usage` guards).
5. The known, documented gap (connection Secrets never Crossplane-owned,
   so claim deletion alone doesn't clean them up) fired exactly as
   designed — the suite deleted them itself as its own cleanup step.
6. Confirmed via SSH to the KVM host (`virsh list`/`pool-list`): no
   orphaned domain or image pool.

Independently re-verified all of the above directly via `kubectl` after
the suite reported PASS, not just trusting its exit code.

**M4 is now fully closed** — all 8 design-doc steps shipped and merged,
and the one deliberately-deferred item (a real, successful Tier B run) is
done. See [[m4-step-tracker]] for the full step-by-step history.
