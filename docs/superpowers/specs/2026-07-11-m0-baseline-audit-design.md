# M0 Design: Baseline Audit, Contract Tests, and Migration Inventory

Date: 2026-07-11
Status: Implemented 2026-07-11 — gates green x2 against the Spot cluster; findings recorded in tests/platform-baseline/README.md and the inventory; human review of inventory dispositions pending (step 7)
Parent: [fable-5-arch-plan.md](fable-5-arch-plan.md) milestone M0
Related: [M1 design](2026-07-11-m1-controlplane-cluster-design.md) (consumer of the headroom data), M2 (consumer of the inventory and the acceptance suites)
Executor: Sonnet 4.6 under human review

## 1. Goal

Freeze a known-good picture of the Rackspace Spot control plane
(`clusters/crossplane`, trust domain `crossplane.rye.ninja`) in two forms:

1. **Executable**: portable chainsaw contract suites in
   `tests/platform-baseline/` that assert the platform's invariants. They
   gate M2 — the migration is done when the same suites pass against
   `controlplane`.
2. **Written**: a regenerable migration inventory of everything that must
   move in M2, plus the cold-start runbook skeleton.

M0 is **read-only** against the live cluster: the only mutations are
ephemeral test namespaces/resources that the suites create and delete
(same pattern as the existing `tests/step-ca/` suites).

## 2. Ground rules for portability

The suites will be run against two different clusters in their lifetime
(Spot now, `controlplane` in M2), so:

- **Parametrize, don't hardcode.** Cluster-specific values live in a
  chainsaw values file per cluster: `tests/platform-baseline/values/
  crossplane.yaml` now, `controlplane.yaml` added in M2. Parameters:
  expected trust domain, Flux Kustomization names, expected provider list,
  step-ca URL, CNPG cluster name/namespace.
- **Assert behavior, not implementation variants.** Example: Spot uses
  `global-network-policy-default-deny/rackspace-spot`; `controlplane` will
  use a different variant. The test proves *an unlabeled namespace cannot
  egress*, not that a policy with a particular name exists.
- **Kubeconfig comes from the catalog** (`rye.ninja/kubeconfig` annotation
  in `clusters/<name>/catalog.yaml`, per project memory) — the runner script
  resolves it; nothing is hardcoded.

## 3. Deliverable A: contract suites (`tests/platform-baseline/`)

Layout follows the existing `tests/step-ca/<case>/chainsaw-test.yaml` +
`resources/` convention. Runner: `.bin/run-platform-baseline.sh <cluster>`
(resolves kubeconfig from the catalog, installs chainsaw via the existing
`.bin/install-chainsaw.sh` if absent, passes the cluster's values file).

| Suite | Asserts |
|---|---|
| `flux/` | Every expected Flux `Kustomization` (`flux-platform`, `flux-platform-external-dns-aws-rolesanywhere`) is `Ready=True`; `GitRepository` sources `Ready=True` with a non-stale artifact |
| `crossplane/` | All 9 providers (`provider-kubernetes`, AWS family + iam/rolesanywhere/route53, Cloudflare family + dns/zone, `provider-github`) report `Healthy=True` and `Installed=True`; the 3 functions (`auto-ready`, `environment-configs`, `go-templating`) installed; `EnvironmentConfig` for platform IAM present; no managed resource stuck `Ready=False` beyond a grace threshold |
| `delegated-zone/` | `XDelegatedHostedZoneAWS` claim `crossplane-rye-ninja` is `Ready=True` and `status.trustDomain` equals the values-file trust domain |
| `step-ca/` | CNPG `Cluster` for `step-ca-db` healthy (all instances ready); step-ca health endpoint 200 and root fingerprint matches the recorded value (commands from `docs/memory/step-ca-connectivity-validation.md`); then **invokes** the existing `tests/step-ca/internal` and `external` suites rather than duplicating them |
| `spiffe/` | A test pod mounting a csi-driver-spiffe volume receives an X.509 SVID whose URI SAN is `spiffe://<trustDomain>/ns/<ns>/sa/<sa>`; trust bundle distributed to the test namespace |
| `eso/` | `ClusterSecretStore` `Ready=True`; the `github` and `cloudflare` `ExternalSecret`s report `SecretSynced` |
| `network-policy/` | Behavioral default-deny probe: a pod in a fresh, unannotated namespace cannot egress (target pod IP:port directly — post-DNAT rule from project memory); a namespace with an explicit allow can; both namespaces deleted on cleanup |

Notes for the implementer:

- Where an invariant is already covered by `tests/step-ca/`, reference it —
  one source of truth per assertion.
- Grace thresholds (e.g. managed-resource readiness) are values-file
  parameters, not constants.
- Each suite must pass twice consecutively before M0 closes, to shake out
  flakes — these suites become the M2 go/no-go gate and false reds there
  are expensive.

## 4. Deliverable B: migration inventory

### 4.1 Generator script (read-only)

`.bin/generate-migration-inventory.sh` — kubectl-only queries (no cloud
credentials; the cloud state of record is the managed resources themselves),
emitting `docs/migration/m2-spot-migration-inventory.md`. Committed as a
snapshot now, regenerated at M2 start to catch drift.

Sections and sources:

| Section | Source | Captured fields |
|---|---|---|
| Crossplane managed resources | `kubectl get managed -o json` | kind, name, `crossplane.io/external-name`, providerConfig ref, deletionPolicy, ready/synced |
| Claims and composites | XRs + claims across namespaces | kind, name, composition ref, connection secret refs |
| XRDs and compositions | cluster-scoped list | name, version — must match what Flux installs on `controlplane` |
| CNPG | `Cluster`/`Database` resources | instances, storage, backup/barman config (step-ca-db today) |
| Flux topology | Kustomizations, sources | entry-point graph, paths, source repos, deploy key secret names |
| Secrets — in repo | `git ls-files` for `*.sops.*` | file, sops recipients, consuming component |
| Secrets — in cluster | Secrets not owned by Flux/cert-manager/ESO | orphans needing a manual decision (expected: bootstrap-era leftovers) |
| DNS | Route53/Cloudflare managed resources + known names | every record resolving to the Spot cluster (`ca.crossplane.rye.ninja` et al.) |
| ESO | stores + ExternalSecrets | backend paths, target secrets |
| PKI identity | step-ca | root fingerprint, issuer chain, trust domain — the values that must NOT change in M2 |
| Resource headroom | `kubectl top nodes` / `top pods -A` | snapshot informing M1/M2 sizing (plan M0 task 2) |
| Workstation/CI deps | catalog annotations, CI matrix | kubeconfig paths, rendered-repo mappings |

### 4.2 Disposition column

The inventory table includes an empty **disposition** column
(`move-state | recreate | retire | n/a`) per item. Filling it is an M2
planning task, not an M0 task — but the column existing forces the M2 review
to touch every row. Two rows are pre-filled by policy from the plan:
step-ca root material = `move-state` (fleet trust must not change);
Rackspace-Spot-specific variants (e.g. default-deny `rackspace-spot`
overlay) = `retire`.

## 5. Deliverable C: cold-start runbook skeleton

`docs/runbooks/control-plane-cold-start.md`:

- **Current state (Spot)**: how to recover today — Spot console access,
  re-run of ADR-3 bootstrap, Flux re-pointing; mostly documenting what
  exists.
- **Target state (home lab)**: ordered skeleton with placeholders —
  TrueNAS → KVM host (`fd97:45c2:b3a1:100::2000`) → NAT64 appliance →
  `controlplane` cluster → step-ca → OpenBao (M3) → Keycloak (M3) →
  workload fleet. Each M1-M3 milestone fills in its section as it lands.

## 6. Execution sequence

All agent steps except where marked; roughly 3 working sessions.

| # | Step | Verify |
|---|---|---|
| 1 | `tests/platform-baseline/` scaffolding + values file + runner script PR | chainsaw dry parse; runner resolves kubeconfig from catalog |
| 2 | Suites: `flux/`, `crossplane/`, `delegated-zone/`, `eso/` | green against Spot |
| 3 | Suites: `step-ca/` (wrapping existing), `spiffe/`, `network-policy/` | green against Spot; test namespaces cleaned up |
| 4 | Full run x2 consecutive | both green; runtime recorded (budget: < 15 min) |
| 5 | `generate-migration-inventory.sh` + committed snapshot | every section non-empty or explicitly `none found`; spot-check 3 external-names against reality |
| 6 | Cold-start runbook skeleton PR | — |
| 7 | **[H]** Review inventory + dispositions policy rows; review runbook | sign-off comment on PR |
| 8 | openbrain + `docs/memory/` updates (record root fingerprint location, suite runner usage) | — |

## 7. Exit criteria

- `.bin/run-platform-baseline.sh crossplane` green twice consecutively,
  runtime under budget, zero leftover test resources.
- Inventory snapshot committed and human-reviewed; regeneration is
  idempotent (running twice produces no diff apart from timestamps).
- Cold-start runbook skeleton merged.
- The suites are documented (README in `tests/platform-baseline/`) as the
  M2 acceptance gate: *M2 is complete when this runner passes with
  `values/controlplane.yaml`* (modulo the trust-domain parameter change).

## 8. Risks and notes

| Item | Handling |
|---|---|
| Spot preemption mid-M0 | Suites are read-only and rerunnable; a preemption during M0 is itself evidence for the migration and gets recorded in the inventory's availability notes |
| Flaky assertions poisoning the M2 gate | The run-twice rule (6.4); grace thresholds parametrized; anything unfixably flaky gets quarantined to an `advisory/` suite that reports but does not gate |
| Inventory staleness by the time M2 starts | Generator is committed and rerun at M2 kickoff; the M0 snapshot exists to diff against, making drift visible |
| CI integration | Out of scope for M0 — suites run from the workstation. GitHub-hosted runners are IPv4-only and will NOT reach the future IPv6-only `controlplane` cluster; if CI execution is ever wanted, it needs a self-hosted runner on VLAN 100 (noted for M5+, not planned) |
