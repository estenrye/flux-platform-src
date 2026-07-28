# talos-cluster-bootstrap

ServiceAccount/RBAC/NetworkPolicy identity for the M4 Talos-bootstrap `Job`
(image: `images/docker/talos-cluster-bootstrap`, script:
`bootstrap.sh` — a close port of `.bin/create-controlplane-cluster.sh`'s
imperative half for unattended, per-claim execution). See
[docs/superpowers/specs/2026-07-26-m4-cluster-lifecycle-design.md](../../docs/superpowers/specs/2026-07-26-m4-cluster-lifecycle-design.md).

Pre-provisioned here, ahead of any claim existing, so OpenBao's
`kubernetes`-auth role (`.bin/configure-openbao-talos-cluster-bootstrap-secrets.sh`)
can be bound to a fixed ServiceAccount name — same reasoning as
`provider-terraform`'s own identity in M4 step 1.

**Contract the `cluster-talos-kvm` Composition (M4 step 3) must honor** when
it creates a bootstrap `Job` for a claim:
- `spec.template.spec.serviceAccountName: talos-cluster-bootstrap`
- `spec.template.metadata.labels["app.kubernetes.io/name"]: talos-cluster-bootstrap`
  (the `NetworkPolicy` here selects on this label, not the Job's name —
  every claim's Job must carry it)
- Runs in the `crossplane-system` namespace.
