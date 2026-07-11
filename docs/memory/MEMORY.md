# Memory Index

- [Mermaid GitHub Rendering](mermaid-github-rendering.md) — Known incompatible Mermaid constructs on GitHub and safe alternatives
- [Memory Location Preference](feedback-memory-location.md) — Memory files live in docs/memory in this repo, not the default ~/.claude path
- [Project Skills Location](project-skills-location.md) — Skills live in .claude/skills/ in this repo, not ~/.claude/skills/
- [Cluster Kubeconfig Lookup](cluster-kubeconfig-lookup.md) — Authoritative kubeconfig path for any cluster is the `rye.ninja/kubeconfig` annotation in `clusters/<name>/catalog.yaml`
- [step-ca Connectivity Validation](step-ca-connectivity-validation.md) — Health check and root CA fingerprint validation commands for `https://ca.crossplane.rye.ninja`
- [Calico NetworkPolicy and DNAT](calico-networkpolicy-dnat.md) — Calico evaluates egress post-DNAT; egress rules must use pod targetPort, not service port
- [M1 Implementation Status](m1-implementation-status.md) — controlplane-on-KVM progress, pins (Talos v1.13.5, libvirt provider 0.8.x), and what remains
- [SOPS Creation Rule Input Path](sops-creation-rule-input-path.md) — sops -e matches rules against the plaintext input path; temp-file encryption can silently skip encryption
