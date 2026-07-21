---
name: m2-step11-restore-drill
description: M2 step 11 executed 2026-07-21 — step-ca-db restore drill passed; NetworkPolicy gotchas for scratch CNPG clusters on controlplane
metadata:
  type: project
---

Per [M2 design](../superpowers/specs/2026-07-13-m2-migration-design.md)
§6 step 11: restored the nightly `step-ca-db` dump
(`stepcas-20260721T021007Z.dump`) onto a scratch, single-instance CNPG
cluster and confirmed step-ca starts against it (`/health` → `{"status":
"ok"}`, root fingerprint matched). Full procedure, including the
NetworkPolicy pitfalls, is now in
[docs/runbooks/step-ca-db-restore.md](../runbooks/step-ca-db-restore.md)
— reusable for the plan's M11 quarterly drills. All scratch resources were torn down; production `step-ca-db`
and `step-certificates` were untouched throughout.

**Key gotcha (generalizes beyond this drill):** any new `cnpg.io/cluster`
name on `controlplane` starts with zero traffic under the namespace's
default-deny posture. Production's NetworkPolicies are scoped by exact
cluster/pod name, so they never cover a scratch cluster — you need both
an *egress* policy (apiserver 6443 for the instance manager, DNS) **and**
an *ingress* policy (5432 from consumers, 8000 from the `cnpg-system`
operator for its own status polling) for the new name. Missing the
ingress half produces a misleading `Instance Status Extraction Error:
HTTP communication issue` on the `Cluster` status that looks like an
operator bug but is just the operator's own health-check traffic being
dropped — `READY` can still show the right count and direct `psql`
connections can still work while that message is showing. Don't trust
that status string over a direct connectivity test.

**RPO finding:** the restored dump was ~3h stale relative to production
by design (nightly schedule); `x509_certs`/`x509_certs_data`/`used_ott`
row counts differed by exactly the certs issued in that window. This is
the correct, expected behavior of a dump-based backup — worth remembering
before treating a future row-count mismatch as a restore failure.

See also [[m2-step8-delegated-zone-migration]] for the sibling M2
state-migration exercise and its own "verify independently, don't trust
a single status source" lesson.
