---
name: harbor-phase1-gotchas
description: Harbor phase 1 (2026-11-14): registry cannot use SeaweedFS web identity, SeaweedFS needs ReadAcp/WriteAcp for x-amz-acl, patching a CreatedOnce ESO Secret gets reverted, token realm follows the request host
metadata:
  type: project
---

Harbor 2.15.4 (chart 1.19.4) runs on core-infra (`applications/harbor`, `harbor-db`); runbook `docs/runbooks/harbor.md`, ADR 0031.

- **Registry S3:** Harbor's registry is distribution 2.8.3 on aws-sdk-go v1: no web-identity credential provider
  (`NoCredentialProviders`). Use a static key limited to the bucket: SeaweedFS identity `harbor-registry` in
  `seaweedfs-s3-config`, key in 1Password `core-infra/harbor-registry-s3`. The `HarborRegistry` STS role is unused.
- **x-amz-acl:** the registry always sends `x-amz-acl: private`; SeaweedFS rejects that with AccessDenied for a
  non-admin identity unless it also has `ReadAcp:<bucket>` and `WriteAcp:<bucket>` (found by testing with aws-cli).
- **CreatedOnce secrets:** ESO reverts in-place patches to `seaweedfs-s3-config` (data-hash drift). Change the
  ExternalSecret template in git, delete the Secret, check it was recreated BEFORE restarting the filers (they mount
  it; the template needs a `secretStoreRef` once it has remoteRefs). Deleting it rotates the generated admin key
  (only `.bin/seaweedfs-restore-drill` reads it, live).
- **Token realm:** Harbor builds the registry's `Www-Authenticate` realm from the request host, so in-cluster
  clients stay on `harbor.harbor.svc.cluster.local` (no split-horizon DNS).
- **ESO templates:** `htpasswd` takes `(user, password, "bcrypt")`.
- **Flux:** source-controller runs 1 replica (the artifact server is leader-only, store per pod).

**Why:** each of these cost a deploy cycle. **How to apply:** before phase 2+, start from the runbook; do not retry
web identity for the registry.
