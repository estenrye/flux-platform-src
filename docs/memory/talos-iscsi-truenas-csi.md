---
name: talos-iscsi-truenas-csi
description: Talos-specific gotchas making truenas-csi iSCSI work (iscsiadm path, non-idempotent discovery)
metadata:
  type: project
---

Two field findings from wiring truenas/truenas-csi v1.1.1 iSCSI on the
controlplane cluster ([[m1-implementation-status]]):

1. **iscsiadm path.** The upstream node plugin's `postStart` hook installs an
   `iscsiadm` shim that does `nsenter --mount=/host/proc/1/ns/mnt --
   /usr/sbin/iscsiadm`. Talos ships iscsiadm at **`/usr/local/sbin/iscsiadm`**
   (iscsi-tools extension), so the stock shim returns exit 127. Patched in
   `applications/truenas-csi/base/patches/node.yaml` (postStart command
   override). Note iscsid runs as its own extension service container
   (`ext-iscsid`), but it shares /etc/iscsi + /var/lib/iscsi with the host
   mount ns, so the PID1-nsenter shim reaches the same DB — the ONLY change
   needed is the binary path.

2. **Discovery is not idempotent.** csi-lib-iscsi runs `iscsiadm -m
   discoverydb -t sendtargets -p <portal> -o new` with `DoDiscovery: true`.
   `-o new` against an already-existing record returns **exit 7**
   (ISCSI_ERR_INVAL). A single failed Stage leaves a discoverydb record that
   makes every retry fail with exit 7 — so one transient failure looks
   permanent. Recovery: delete the stale record on the affected node's
   csi-node pod:
   `kubectl exec -n truenas-csi <node-pod> -c csi-node -- /usr/sbin/iscsiadm
   -m discoverydb -t sendtargets -p '[fd97:45c2:b3a1:100::1000]:3260' -o
   delete`. This is upstream behavior; the storage baseline suite passes on
   clean state.

**HARD BLOCKER (filed):** truenas-iscsi does not work on this IPv6-only
cluster at all. The pinned csi-lib-iscsi (`v0.0.0-20240130`, unfixed on
master) parses portals with `strings.Split(portal, ":")[0]/[1]`, shredding
any IPv6 address, so the `/dev/disk/by-path/ip-<portal>-...` search never
matches the real (unbracketed) udev symlink — NodeStageVolume fails
"find device path". Discovery + login + device creation all work manually;
only the library's parsing is IPv4-only. No `iscsiPortal` config value fixes
it. Issues: kubernetes-csi/csi-lib-iscsi#94 (root) + truenas/truenas-csi#45
(tracking). **truenas-nfs (RWX) works fine and is the storage path until an
upstream fix lands.**

iSCSI portal is bound to the NAS static ULA (see
[[m1-implementation-status]]); bracketed IPv6 (`[addr]:3260`) is what the
config uses — an UNbracketed portal silently creates a malformed
`addr:3260:3260` discoverydb record.
