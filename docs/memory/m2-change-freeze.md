---
name: m2-change-freeze
description: M2 step 10 change freeze on clusters/crossplane/ declared 2026-07-21; soak clock started
metadata:
  type: project
---

Per [M2 design](../superpowers/specs/2026-07-13-m2-migration-design.md)
§4.7 and execution-sequence step 10: the change freeze on
`clusters/crossplane/` is **declared, effective 2026-07-21**. No
source-repo changes that render into the Spot cluster entry are allowed
from this point until decommission (step 13). Enforcement is social
(per the design; no automated label/CI check exists for this repo) — if
a PR touches `clusters/crossplane/`, it should be called out and held
until decommission.

**Why now:** the platform-baseline gate (step 10's other requirement)
was met the same day — full baseline runner passed clean twice
consecutively against `controlplane` with `STEP_CA_EXTERNAL_GATE=gate`,
after the zone-firewall and public-DNS work landed (see
[[unifi-zone-firewall]], [[external-dns-multi-instance-collision]]).

**Soak clock**: starts 2026-07-21, 7 days per the design (through
~2026-07-28), plus margin before the step 12 go/no-go review.

**Status of the frozen stack**: `crossplane-rye-ninja` delegated-zone
claim is still fully live (no `deletionPolicy: Orphan` set) — step 8
(state migration) has not started. The freeze does not block step 8
work in `clusters/controlplane/` or the source repo's other paths, only
changes that would render into `clusters/crossplane/`.
