---
name: truenas-api-surface
description: What the TrueNAS JSON-RPC API can and cannot do for ZFS admin (no canmount/umount/zfs-allow), and how to call it
metadata:
  type: reference
---

TrueNAS 25.10 JSON-RPC API (`wss://nas.rye.ninja/api/current`, auth via
`auth.login_with_api_key`) — findings from the M1 replication work
(2026-07-13), probed with the Full Admin `csi-controlplane` key
(SOPS: `clusters/controlplane/resources/truenas-csi.api-credentials.sops.yaml`,
key at `.stringData["api-key"]`, decrypt with
`SOPS_AGE_KEY_FILE=clusters/controlplane/.sops.age-key`):

- **Not exposed at all** (769 methods checked via `core.get_methods`):
  `zfs allow`, dataset mount/umount, `canmount` (absent from
  `pool.dataset.update`'s schema). Anything in that class needs root shell
  on the NAS — even a Full Admin API key cannot do it.
- `zfs.resource.query` reads any dataset/snapshot properties (incl. GUIDs).
- `replication.run_onetime` + `keychaincredential.*` exist for
  NAS-side zettarepl pushes (would need a NAS→host SSH credential).
- No websockets lib in the repo venv; a scratch venv + ~40-line client
  works (JSON-RPC 2.0, id-matched request/response).

Related: [[m1-implementation-status]], [[crossplane-credential-rotation]].
