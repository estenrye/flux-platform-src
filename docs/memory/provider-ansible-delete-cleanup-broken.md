---
name: provider-ansible-delete-cleanup-broken
description: AnsibleRun's deletionPolicy Delete + runPolicy ObserveAndDelete does not trigger cleanup on v0.8.0 -- confirmed live, tracked upstream at issue #362
metadata:
  type: reference
---

`provider-ansible` (`xpkg.upbound.io/crossplane-contrib/provider-ansible:v0.8.0`,
this fleet's pinned version) does not actually run cleanup logic when an
`AnsibleRun` is deleted, even with both `spec.deletionPolicy: Delete` and the
`ansible.crossplane.io/runPolicy: ObserveAndDelete` annotation set (the
combination [crossplane-contrib/provider-ansible#362](https://github.com/crossplane-contrib/provider-ansible/issues/362)
documents as necessary). Confirmed live 2026-08-06 via a throwaway `AnsibleRun`
that unconditionally logs the full `ansible_provider_meta` variable to a
marker file on every run: applying it correctly showed
`ansible_provider_meta.<name>.state == 'present'`; deleting it removed the
object from the API in ~5 seconds with no second playbook run ever firing
(confirmed by re-reading the marker file afterward -- only the original
`present` entry ever appears). Tested both with and without the annotation,
same result both times.

This differs from the original issue #362 report (v0.6.0), where the same
annotation DID trigger a delete-time run, just with a different bug (an
infinite deletion loop needing manual finalizer removal to break). v0.8.0
shows neither the loop nor a working trigger -- possibly a regression between
versions, possibly something else about how/where the annotation needs to be
set. Commented on the issue with this fleet's exact repro manifest and
results: https://github.com/crossplane-contrib/provider-ansible/issues/362#issuecomment-5201279845

**Also confirmed as a side finding**: `ansible_provider_meta`'s key is the
`AnsibleRun`'s own `metadata.name` (e.g. `ansible_provider_meta.my-thing.state`),
NOT a fixed literal like `managed_resource` -- the provider's own design doc
uses `managed_resource` only as an illustrative placeholder name, which reads
ambiguously without having tested it live.

**How to apply:** [[xnetworksegment-bridge-cleanup]] (if that memory exists)
or `applications/crossplane-resources/xnetworksegment/`'s own bridge
management deliberately relies on `AnsibleRun`'s default `deletionPolicy:
Orphan` instead -- a segment's netplan file is left on disk when the claim is
deleted (harmless but untidy, confirmed via the leftover `60-br200.yaml` after
tearing down `observability`). Do not attempt to wire up delete-time netplan
cleanup via this mechanism until the upstream issue is resolved -- re-test
live against whatever version is pinned at the time before relying on it,
since this fleet's own result differs from the original report's.
