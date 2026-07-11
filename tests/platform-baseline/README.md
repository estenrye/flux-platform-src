# Platform Baseline Contract Suites

Executable invariants of the platform control plane. Written in M0 against
the `crossplane` (Rackspace Spot) cluster; **these same suites are the M2
migration acceptance gate** — M2 is complete when the runner passes with a
`controlplane` values file.

Design: [docs/superpowers/specs/2026-07-11-m0-baseline-audit-design.md](../../docs/superpowers/specs/2026-07-11-m0-baseline-audit-design.md)

## Running

```bash
.bin/run-platform-baseline.sh crossplane
```

The runner resolves the kubeconfig from `clusters/<name>/catalog.yaml`
(`rye.ninja/kubeconfig` annotation), sources
`tests/platform-baseline/values/<name>.env`, installs chainsaw if needed,
runs these suites, then runs the pre-existing `tests/step-ca/` capability
suites (skip with `RUN_STEP_CA_SUITES=false`).

Anti-flake rule: a change to these suites is only mergeable after **two
consecutive green runs** — they gate the migration and false reds there are
expensive.

## Suites

| Suite | Contract |
|---|---|
| `flux/` | every Kustomization and GitRepository Ready |
| `crossplane/` | expected providers/functions/EnvironmentConfigs healthy; all managed resources Ready+Synced; MR count ≥ recorded floor |
| `delegated-zone/` | zone claim Ready, `status.trustDomain` matches values |
| `eso/` | all secret stores Ready, all ExternalSecrets synced |
| `step-ca/` | CNPG primary healthy; CA endpoint serves within retry budget; root fingerprint matches the **pinned trust anchor** |
| `spiffe/` | csi-driver-spiffe issues an SVID with `spiffe://<trustDomain>/ns/<ns>/sa/<sa>` |
| `network-policy/` | behavioral default-deny: pod-to-pod denied without policy, allowed with explicit ingress+egress allows (by pod IP, post-DNAT rule) |

## Portability rules

1. Cluster-specific expectations live only in `values/<cluster>.env`.
2. Assert behavior, not implementation variants (e.g. default-deny is proved
   by a probe, not by looking up the `rackspace-spot` overlay by name).
3. Scripts inherit `KUBECONFIG` from the runner — never hardcode paths.
   (`tests/step-ca/` predates this rule and gets parametrized in M2.)

## Known audit findings asserted as-is (2026-07-11)

Recorded in `values/crossplane.env`, to be resolved by M2 (not on Spot):

- Trust domain is `cluster.local`, not `crossplane.rye.ninja` (ADR-16 drift);
  AWS Roles Anywhere ABAC conditions therefore pin `cluster.local` URIs and
  M2's re-enrollment under `controlplane.rye.ninja` is mandatory work.
- `step-ca-db` CNPG cluster degraded ("Creating a new replica", 1 of spec'd
  instances ready).
- Public CA endpoint (`ca.crossplane.rye.ninja`) has **sustained outage
  windows** (25% availability in a 60s sample; TLS handshake timeouts for
  minutes at a time; envoy-gateway controller logged 413 restarts in 47h,
  exit code 1, consistent with leader-election churn on Spot). The in-cluster
  CA path is healthy — `tests/step-ca/internal` passes — so the defect is in
  the public ingress path only. `tests/step-ca/external` is quarantined to
  advisory on this cluster (`STEP_CA_EXTERNAL_GATE=advisory`).
- The root CA was rotated (~28d before 2026-07-11) and the internal suite's
  hardcoded fingerprint went stale unnoticed — fixed by injecting the live
  fingerprint at test time; the pinned trust anchor now lives in one place
  (`values/<cluster>.env`).

## Advisory vs gate

Gate failures exit nonzero. Degradations that are recorded findings print
`ADVISORY:` lines but pass (CNPG HA below spec, CA endpoint needing >1
attempt). When a finding is fixed, promote its advisory back to a gate by
tightening the values file.
