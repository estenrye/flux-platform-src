---
name: feedback-urgency-is-users-call
description: Don't unilaterally downgrade a finding's priority to "not urgent, follow-up later" — surface it and let the user decide
metadata:
  type: feedback
---

When I finish a piece of work and surface a secondary finding (e.g., a
deprecation with a runway, a follow-up bug), don't editorialize it as
"not urgent" and move on unprompted. State what I found and its actual
technical timeline (e.g., "one CNPG minor version of runway"), and let
the user decide the priority.

**Why:** During M3 step 4 (2026-07-23), I found production's CNPG
backup config used an API being removed in the next minor version. I
labeled it "not urgent, not blocking M3" and proposed deferring it. The
user pushed back hard: *"your assessment that this is not urgent is not
acceptable. I as the human have deemed it urgent enough to deal with
now."* They were right to push back — I don't have full context on their
risk tolerance, release calendar, or how they weigh technical debt
against milestone velocity. My "not urgent" was really "not urgent to
finish this session cleanly," which isn't a decision that's mine to
make.

Compounding this: my stated reason for deferring (a Secret I claimed had
no `data` in the vendored manifest) turned out to be my own investigation
error — I grepped only the lines *after* a resource's `name:` field and
missed `data:`, which sorts before it alphabetically. Don't let a
shallow "this looks broken" read become the justification for
downgrading priority; if a finding is the stated reason to defer
something, re-verify it thoroughly before acting on it.

**How to apply:** Report findings with their real technical timeline and
blast radius, flag genuine open questions plainly, and ask or wait for
direction on priority — don't pre-decide it as "later" in the same
breath as discovering it. If the user overrides a priority call, treat
it as data about how they want this collaboration to work going
forward, not just a one-off correction.
