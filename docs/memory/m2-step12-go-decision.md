---
name: m2-step12-go-decision
description: M2 step 12 go/no-go decided GO by Esten 2026-07-21, soak curtailed from the planned 7 days to <1 day
metadata:
  type: project
---

Esten made the [M2 design](../superpowers/specs/2026-07-13-m2-migration-design.md)
§6 step 12 go/no-go call on **2026-07-21**: **Go**. This is a human
[H]-marked decision per the design and is recorded here verbatim rather
than inferred.

**Why this matters for future reads:** the design's soak was 7 days
(2026-07-21 through ~2026-07-28). The Go decision landed less than a day
into that window — Esten explicitly chose not to wait out the full soak.
Evidence available at decision time: two consecutive clean
`.bin/run-platform-baseline.sh controlplane` runs
(`STEP_CA_EXTERNAL_GATE=gate`), [[m2-step8-delegated-zone-migration]]
verified against AWS ground truth (zero external-name diff, no
cloud-side recreation), and [[m2-step11-restore-drill]] passing. No
evidence of a problem — this is an accepted risk (less soak time than
planned), not a discovered gap being papered over. See
[ADR-24](../adr/0024-m2-control-plane-service-migration-off-spot.md)'s
status section for the durable record of this deviation.

**Consequence:** step 13 (decommission) is now unblocked and proceeds
next. The [[m2-change-freeze]] on `clusters/crossplane/` stays in effect
through decommission (it's lifted by decommission removing the frozen
path, not by a separate unfreeze action).
