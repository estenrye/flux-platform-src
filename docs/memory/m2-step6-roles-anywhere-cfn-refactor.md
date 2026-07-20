---
name: m2-step6-roles-anywhere-cfn-refactor
description: Recent Crossplane install + CloudFormation refactor commits exist to deploy a new AWS Roles Anywhere trust root for ca.rye.ninja
metadata:
  type: project
---

Commits `8800c45` (apiserver 6443 egress pre-flight), `fc52447` (Crossplane
install layer on controlplane), and `27e71c3` (CloudFormation stack
refactor to be generalized for individual clusters) are M2 step 6 work
([2026-07-13-m2-migration-design.md](../superpowers/specs/2026-07-13-m2-migration-design.md)
step 6: "Crossplane + providers + functions + XRDs/compositions via Flux;
Roles Anywhere bootstrap").

**Why:** the M2 migration mints a fresh step-ca root/intermediate on
`controlplane` (plan amendment A1/A5 in the migration design) — every AWS
Roles Anywhere trust anchor needs to re-enroll against the new root
regardless, since the old one only trusted Spot's CA. The CloudFormation
stack that provisions Roles Anywhere trust anchors/profiles/IAM roles was
originally single-cluster; it's being generalized so the same stack can
deploy a trust anchor for `ca.rye.ninja` (the new root) without being
hardcoded to the old Spot-era setup.

**How to apply:** if working on Crossplane provider bootstrap, AWS IAM
roles, or Roles Anywhere trust anchors on `controlplane`, this is the
context — check `providers/aws/roles-anywhere/` and
`providers/aws/iam-roles/trust-anchor-*.yaml` for the current state, and
the M2 design's step 6/4.4 for the full bootstrap sequence (static cred →
new trust anchor/profiles/ABAC → flip to SVID auth → quarantine static
cred).
