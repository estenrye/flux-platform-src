---
name: feedback-dont-inflate-tradeoff-costs
description: When evaluating architecture options, don't ascribe motivations or inflate downsides (isolation, capacity limits) without checking the user's actual stated constraints first
metadata:
  type: feedback
---

Don't attribute a motivation to a past decision (e.g. "VLAN 200 was built for
L2 isolation") or inflate a tradeoff's cost (e.g. "doesn't generalize" framed
as a capacity/scaling wall) without first checking it against what the user
has actually said they need. Ground framing in their stated priorities and
concrete numbers, not defensive worst-casing.

**Why:** During observability-cluster network architecture review
(2026-08-06), corrected twice in one exchange: (1) claimed VLAN 200 existed
for L2/firewall-zone isolation between clusters — the user provisioned it
specifically to fix an ICMPv6 hairpin routing bug, isolation was never the
goal, per [[m4-network-architecture-no-isolation-requirement]]. (2) raised
"doesn't generalize to future clusters" against sharing controlplane's VLAN,
implying an address-capacity concern — user pointed out a /64 is 2^64
addresses, capacity is a non-issue at homelab scale. Both times the honest
remaining concern was much narrower (or nonexistent) than how I'd framed it.

**How to apply:** When listing downsides of an option, ask "is this actually
a constraint this user has, or am I assuming a general best-practice concern
applies here?" Prefer citing the user's own words for *why* a past decision
was made over inferring intent from code comments/architecture docs, even
when those docs discuss related concerns (e.g. firewall-zone code existed
for a different bug fix, not because isolation was the goal). If unsure
whether a tradeoff matters to them, ask rather than presenting it as settled
cost in a recommendation.
