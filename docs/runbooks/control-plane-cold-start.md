# Runbook: Control Plane Cold Start

Status: skeleton (M0, 2026-07-11). Sections marked TODO are filled by the
milestone that builds the component (M1-M3). Executed end-to-end at least
once during M11 hardening.

## When to use

Total loss of the control plane (site power loss, host failure, cluster
corruption) — the ordered procedure to bring the platform back from zero.

## Current state: crossplane cluster on Rackspace Spot

Until M2 completes, the control plane is the Spot cluster and recovery is:

1. **Cluster gone/unrecoverable**: re-provision via `spotctl` per ADR-3
   (`.bin/create-crossplane-controlplane-cluster.sh`), then re-bootstrap
   Flux Operator against `estenrye/flux-platform-rendered`
   (`clusters/crossplane` path). Kubeconfig annotation in
   `clusters/crossplane/catalog.yaml` must be updated if the path changes.
2. **Secrets**: `flux-system/sops-age` must be restored first (from
   `clusters/crossplane/.sops.age-key` holder's keychain) or Flux cannot
   decrypt; ESO needs `external-secrets-operator/onepassword-sdk-token`
   restored (1Password service account) before ExternalSecrets sync.
3. **step-ca**: root/intermediate key material restores from
   `step-ca/step-certificates-secrets` — **WARNING (M0 finding)**: the
   `step-ca-db` CNPG cluster has NO barman backup configured; until that is
   fixed, loss of the cluster loses issuance history/CRL state (root key
   survives via secrets, so fleet trust survives, but revocation state does
   not).
4. **Verification**: `.bin/run-platform-baseline.sh crossplane` green =
   recovered.

## Target state: controlplane cluster in the home lab (fills in M1-M3)

Recovery order — each layer must be verified before the next:

1. **Network** (UniFi): VLAN 100 up, BGP enabled (AS 64512), static route
   for `fd97:45c2:b3a1:100::/64`. Verify: gateway reachable, RA/SLAAC on
   VLAN 100.
2. **TrueNAS Scale** (`nas.rye.ninja`): pools imported, iSCSI + NFS services
   up, API reachable. Verify: `curl -k https://nas.rye.ninja/api/...`.
   TODO(M1): exact dataset list and service checklist.
3. **KVM host** (`mf-ms-a2-01`, ULA `fd97:45c2:b3a1:100::2000`): libvirt up,
   `zpool import vmpool`, bridges up. Verify: `virsh list --all`,
   `zpool status vmpool`. TODO(M1): host prep script reference.
4. **NAT64/DNS64 appliance** (`nat64-01`, ULA `::64`): boots with the
   cluster VMs; without it, IPv4-only egress (GitHub/ghcr) is down and Flux
   cannot pull. Verify: DNS64 synthesizes AAAA for `github.com`; v6 ping
   `64:ff9b::` prefix. Break-glass if unrecoverable: TODO(M1) git bundle /
   image side-load procedure.
5. **controlplane cluster VMs**: start control plane nodes first, then
   workers (`virsh start`), or rebuild via
   `.bin/create-controlplane-cluster.sh` + etcd snapshot restore.
   Verify: `talosctl health`. TODO(M1): etcd restore procedure reference.
6. **step-ca**: CNPG cluster recovers from barman (Garage, after M3) or
   redeploys with root material from SOPS. Verify: fingerprint check
   (docs/memory/step-ca-connectivity-validation.md) matches
   `454b03bf485f2a70f84b6c290e3ff3eaaef30ef192822c5f69d8c593f7635add`
   (update if root legitimately rotates - see M0 inventory PKI section).
   TODO(M2): exact restore-vs-redeploy decision tree.
7. **OpenBao**: TODO(M3) - unseal from SOPS key shares; raft restore from
   Garage snapshot if needed. Until OpenBao is up, ESO across the fleet
   cannot sync (workloads keep running on last-synced secrets).
8. **Keycloak**: TODO(M3) - CNPG restore; verify OIDC discovery endpoint;
   Pinniped Supervisor follows.
9. **Fleet reconciliation**: workload clusters reconnect automatically
   (Flux pulls, leaf NATS replays after M10). Verify fleet health in
   Grafana (after M5).
10. **Verification**: `.bin/run-platform-baseline.sh controlplane` green =
    recovered.

## Dependencies that must survive independently of the platform

- SOPS age keys (bootstrap trust): holder's keychain + offline copy.
- This repo (`flux-platform-src`) and the rendered repos: GitHub.
- Root CA key material: SOPS-encrypted in repo + `step-certificates-secrets`.
- Kubeconfigs: paths per `catalog.yaml` annotations; regenerate via
  provisioning tooling if lost.
