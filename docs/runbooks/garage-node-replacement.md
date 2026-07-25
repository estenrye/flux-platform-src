# Runbook: Garage node replacement (`controlplane`)

Garage runs as a 3-replica `StatefulSet` (`garage-0`/`garage-1`/`garage-2`),
one zone each (`zone-a`/`zone-b`/`zone-c` — Garage's own redundancy
concept, not a real physical zone on this single-KVM-host cluster; it
just guarantees the 3-way replication factor spreads across all 3
replicas rather than letting 2 land in the same "zone"), each with its
own `data`/`meta` PVC pair on `democratic-csi-iscsi`.

**Check which scenario applies before doing anything** — they need
different amounts of work:

## Scenario A: the Talos node died, storage survived

The common case. Garage's `data`/`meta` PVCs are on network-attached
iSCSI storage (TrueNAS-backed, via democratic-csi), not node-local disk —
losing the Talos VM does **not** lose the PVCs. Garage persists its own
node identity (an Ed25519 keypair) in its metadata store, not derived
fresh on every process start, so a rescheduled pod that re-attaches the
*same* `meta` PVC comes back as the *same* Garage node automatically —
no layout change needed at all.

This is exactly [talos-node-replace.md](talos-node-replace.md)'s
existing worker-node procedure — follow it as-is:

```sh
export TALOSCONFIG=~/.talos/homelab-controlplane.yaml
kubectl --kubeconfig ~/.kube/homelab/controlplane.yaml drain controlplane-wk-N \
  --ignore-daemonsets --delete-emptydir-data
tofu -chdir=providers/kvm/controlplane taint 'module.talos_node["controlplane-wk-N"].libvirt_volume.system'
tofu -chdir=providers/kvm/controlplane taint 'module.talos_node["controlplane-wk-N"].libvirt_domain.vm'
.bin/create-controlplane-cluster.sh
kubectl --kubeconfig ~/.kube/homelab/controlplane.yaml uncordon controlplane-wk-N
```

Verify the Garage pod that was on that node rejoined with its original
identity (node ID unchanged):

```sh
kubectl -n garage exec garage-0 -- /garage status
# HEALTHY NODES should list all 3 original node IDs; none marked as new/unknown
```

If all 3 node IDs match what `garage layout show` already knows about,
you're done — no layout surgery needed.

## Scenario B: the underlying storage (the `meta`/`data` PVCs) is also lost

A genuine disk-loss scenario — the pod comes back at the same
StatefulSet ordinal but with fresh, empty PVCs, so Garage's `garage-init`
container generates a **new** node identity on first boot. The cluster's
layout still references the old (now-gone) identity, and the new pod
isn't in the layout at all yet. This is also the deliberate path for
swapping a healthy-but-being-decommissioned replica onto new storage
(capacity change, planned hardware move) — same commands either way.

1. **Find the old and new node IDs**:

   ```sh
   kubectl -n garage exec garage-0 -- /garage status
   # note the ID for the replaced ordinal under "HEALTHY NODES" (new) and
   # check `garage layout show` for the stale ID still listed but no
   # longer reachable
   kubectl -n garage exec garage-0 -- /garage layout show
   ```

2. **Assign the new node's role, replacing the old one in a single
   operation** (verified live against this cluster — `garage layout
   assign --help` confirms the `--replace` flag exists for exactly this):

   ```sh
   kubectl -n garage exec garage-0 -- /garage layout assign <new-node-id> \
     --replace <old-node-id> \
     -z zone-a \
     -c 45.0GiB
   ```

   Match `-z`/`-c` to whatever the replaced node originally had
   (`garage layout show`'s output before the replacement, or the
   `values.yaml`/PVC size this StatefulSet ordinal was provisioned
   with — currently 50Gi data volumes, `garage status` reports ~45.0
   GiB usable per node after Garage's own overhead).

3. **Apply the staged layout change**:

   ```sh
   kubectl -n garage exec garage-0 -- /garage layout apply --version <N>
   # <N> is the layout version shown by `garage layout show` after staging
   # (it increments the *current* version shown, e.g. current version 1 -> apply --version 2)
   ```

4. **Watch resync** — Garage's own replication (3-way, one copy per
   zone) automatically re-populates the new node's `data` volume from
   the other 2 healthy replicas; no manual data copy:

   ```sh
   kubectl -n garage exec garage-0 -- /garage status
   # watch DataAvail / resync progress; healthy once all 3 nodes report
   # normally and bucket list/get round-trips succeed from every replica
   ```

5. **Verify** with the same S3 round-trip smoke test used when Garage was
   first provisioned (put/get/delete against each bucket:
   `step-ca-db-barman`, `openbao-db-barman`, `keycloak-db-barman`,
   `openbao-snapshots`, plus reserved `lgtm`/`jwks`):

   ```sh
   kubectl -n garage exec garage-0 -- /garage bucket list
   ```

## Notes

- **RPC secret and admin token are shared, not per-node** — they come
  from the same `garage-admin` Secret (SOPS-encrypted,
  `clusters/controlplane/secrets/garage-admin.sops.yaml`) mounted
  identically into every StatefulSet replica, so a replacement pod at
  the same ordinal picks them up automatically. Nothing to rotate or
  re-provision for a same-identity or new-identity replacement.
- **Never remove a node's layout role while only 2 zones are healthy** —
  with 3-way replication across 3 zones, losing a second zone mid-resync
  risks unavailability for any object whose remaining copies both lived
  on the lost zones. Confirm `garage status` shows the other 2 nodes
  fully healthy before staging a `layout remove`/`assign --replace`.
- This has not yet been exercised as a live drill on this cluster (Garage
  was redeployed/reset several times during M3 step 3's initial
  build-out, which is a different scenario — a full teardown/recreate,
  not a single-node replacement against otherwise-stable data). Treat
  the `--replace`/`apply --version` sequence above as verified-by-CLI-
  help-text-and-architecture, not yet verified-by-drill; a first real
  drill should confirm the exact resync timing and update this note.
