---
name: nat64-tayga-unit-race
description: 2026-11-13 NAT64 outage on nat64-01 - packaged tayga init script (start-stop-daemon --exec) lost a race with tayga-priv after unattended-upgrades; fixed with a native unit; how to reach the VM
metadata:
  type: project
---

On 2026-11-13 06:24 UTC `apt-daily-upgrade` on `nat64-01` re-executed systemd and restarted services. The packaged
`/etc/init.d/tayga` (wrapped as `tayga.service`) failed to start because `start-stop-daemon --exec /usr/sbin/tayga` sees
`tayga-priv`'s process and refuses. Well-known-prefix NAT64 (`64:ff9b::/96`) was down for ~8 h: GitHub/ghcr unreachable,
a new Talos node's kubelet stuck pulling `ghcr.io`. Native-prefix NAT64 (`tayga-priv`) kept working.

**Fix.** `tayga.service` is a native unit in `providers/kvm/modules/nat64-appliance/templates/user-data.yaml.tftpl`
(also applied live). See the runbook `nat64-appliance-rebuild.md`, Gotchas. A Healthchecks probe now watches the path.

**How to reach the VM.** `ssh automation-user@mf-ms-a2-01.usmnblm01.rye.ninja`, then
`virsh -c qemu:///system list` (plain `virsh` lists nothing). `automation-user` has no key on the VM itself; run commands
as root through the guest agent: `virsh -c qemu:///system qemu-agent-command nat64-01 '{"execute":"guest-exec",...}'`
(`guest-exec` returns a pid, then `guest-exec-status`).

**Why:** a stale cluster node or mirror failure that looks like a registry problem can be NAT64 being down.
**How to apply:** check `systemctl is-active tayga tayga-priv` on the VM before debugging registries.
