---
name: eso-createdonce-trust-policy-edits
description: How to change the CreatedOnce seaweedfs-iam-config Secret (trust policies); live patches are reverted, spec changes do not re-render
metadata:
  type: project
---

`seaweedfs-iam-config` is an ExternalSecret with `refreshPolicy: CreatedOnce`.

- A live patch of the Secret is reverted by ESO within seconds (data-hash drift), even for CreatedOnce.
- A merged change to the ExternalSecret template does **not** update the existing Secret.
- What works: merge the template change, then patch the Secret with the same new content; ESO sees drift, re-renders from
  the new template, and the result persists. Then `kubectl -n seaweedfs rollout restart sts/seaweedfs-filer`: the filers
  read the IAM config only at start.
- Used for the Harbor restore drill (2026-11-15, `docs/runbooks/harbor.md`); the trust entry for `harbor-db-drill` was
  temporary.

Related: [[harbor-phase1-gotchas]].
