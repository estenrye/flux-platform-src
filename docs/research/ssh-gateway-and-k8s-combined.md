# Research Addendum: Combined SSH Gateway + Kubernetes Command Execution

**Date:** 2026-07-30
**Requirement:** VPN-less SSH access to customer hypervisors for support engineers/developers, ideally from the same platform providing governed K8s command execution (see `adhoc-command-execution-platform.md`).

## Yes — several candidates from the original list do both

**Teleport** — Strongest combined fit. Born as an SSH gateway; adds K8s, DB, app, and desktop access behind one identity-aware proxy. OIDC SSO issues short-lived certificates for both SSH and kubectl. Session recording/replay, RBAC, JIT access requests, and a unified audit log across both protocols. VPN-less: agents on hypervisors dial out (reverse tunnel) to the proxy, so no inbound firewall holes at customer sites — ideal for reaching customer hypervisors. Also the only one with MCP access controls for your AI-agent consumers.

**StrongDM** — Single control plane for SSH, RDP, K8s, and databases with SSO-backed identity, JIT approvals, and recorded, text-searchable sessions. Gateway/relay model works without VPN. Enterprise-priced; less AI-agent-native.

**Border0 (now Tailscale)** — Protocol-aware proxy covering SSH, K8s, RDP, and DBs with identity-tied sessions, SSH session recording, and command visibility. Post-acquisition it pairs with Tailscale's mesh; roadmap consolidation risk is worth watching.

**HashiCorp Boundary** — Brokers SSH and K8s access with OIDC and Vault credential injection; SSH session recording in the enterprise tier. Weaker command-level K8s audit than Teleport/StrongDM.

## Doesn't cover SSH

Hoop.dev (has SSH support but its depth is in command/data governance, not hypervisor SSH at scale — evaluate before relying on it), Paralus (kubectl only), Botkube/Kubiya/kagent (K8s agents only). If you chose Paralus for OSS K8s access, you'd need to pair it with a separate SSH solution — at which point a unified platform is simpler.

## Hypervisor caveat

Confirm agent installability on your hypervisor OSes. Teleport/StrongDM/Boundary agents run on standard Linux, which covers KVM/Proxmox/XCP-ng hosts; ESXi does not allow third-party agents, so ESXi hosts need agentless SSH proxying (Teleport supports OpenSSH/agentless nodes via certificate trust) or a jump-host pattern.

## Recommendation

This requirement strengthens the case for **Teleport** as the core platform: one OIDC identity, one policy engine, one audit trail spanning kubectl (humans + AI agents) and SSH to customer hypervisors, with reverse tunnels eliminating VPN. StrongDM is the main commercial alternative if you prefer a fully managed control plane.

## Sources

- [Teleport secure access configuration (2026)](https://oneuptime.com/blog/post/2026-01-25-teleport-secure-access-kubernetes/view)
- [StrongDM: Teleport alternatives](https://www.strongdm.com/blog/alternatives-to-gravitational-teleport) · [Boundary alternatives](https://www.strongdm.com/blog/alternatives-to-hashicorp-boundary)
- [StrongDM 2026 review](https://zero-trust-insider.contentwave.net/article/strongdm-2026-review-zerotrust-access-broker-for-databases) · [CyberSecTool StrongDM profile](https://www.cybersectool.com/tools/strongdm)
- [Border0 SSH session recording](https://www.border0.com/blogs/introducing-ssh-session-recording-and-ssh-aware-proxies) · [Border0 + Tailscale](https://tailscale.com/blog/border0-free-trial)
