# 14. Workload Cluster Bootstrap and Lifecycle

Date: 2026-06-10

## Status

Accepted

## Context

The Crossplane control plane cluster (see ADR-3) manages infrastructure for
workload clusters, but workload clusters themselves need Flux installed and
configured to receive application manifests from the rendered repository.
Each workload cluster also requires:

- A unique SPIFFE trust domain for workload identity isolation (see ADR-16)
- Registration with the Crossplane control plane so that its infrastructure
  claims can be reconciled
- Network policies, priority classes, and other platform baseline components
  that must be present before application workloads are deployed

The bootstrap sequence is distinct from the control plane bootstrap (ADR-3)
because workload clusters do not run Crossplane — they consume platform
infrastructure provisioned by the control plane cluster.

## Decision

We bootstrap workload clusters using a defined sequence executed via scripts
in the `.bin/` directory. The sequence is:

### Phase 1: Cluster provisioning

Provision the Kubernetes cluster using the appropriate provider tooling
(e.g., `spotctl` for Rackspace Spot, `eksctl` for AWS EKS, `talosctl` for
Talos Linux). The cluster must be reachable via `kubectl` before proceeding.

Key scripts:
- `.bin/bootstrap-cluster.sh` — interactive bootstrap wizard
- `.bin/deploy-cluster.sh` — non-interactive deployment for known cluster configs

### Phase 2: SOPS key delivery

Each cluster needs the age private key to decrypt SOPS-encrypted secrets
committed to the rendered repository:

```bash
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=/path/to/age.key
```

This secret must exist before Flux can reconcile any SOPS-encrypted manifest.

### Phase 3: Flux bootstrap

Install Flux and point it at the rendered repository for this cluster:

```bash
flux bootstrap github \
  --owner=<rendered_repo_owner> \
  --repository=<rendered_repo_name> \
  --branch=main \
  --path=clusters/<cluster-name>
```

Flux creates a deploy key on the rendered repository and begins reconciling.
At this point, Flux will attempt to reconcile all components listed in
`clusters/<cluster-name>/kustomization.yaml`.

### Phase 4: SPIFFE trust domain configuration

Before cert-manager-spiffe-csi-driver is deployed, configure the cluster's
unique trust domain. See ADR-16 for requirements and the exact configuration
steps. The trust domain must match the `status.trustDomain` of the cluster's
`XDelegatedHostedZoneAWS` claim on the Crossplane control plane.

### Phase 5: Control plane registration

Create the `XDelegatedHostedZoneAWS` claim on the Crossplane control plane
cluster to provision the cluster's delegated DNS zone, IAM role, and Roles
Anywhere profile. This step requires the Crossplane control plane to be
healthy and the `csi-driver-spiffe-ca` trust anchor to be registered with
AWS IAM Roles Anywhere (see ADR-7 Phase 2).

### Decommissioning

To decommission a workload cluster:
1. Delete the `XDelegatedHostedZoneAWS` claim — this removes IAM and DNS
   resources via Crossplane.
2. Delete the cluster entry from `clusters/` in this repository and from the
   rendered repository.
3. Destroy the cluster using the provider tooling.
4. Remove the deploy key from the rendered repository.
5. Revoke the intermediate CA certificate on step-ca (if Pattern D is in use).

## Consequences

- Workload cluster bootstrap is a multi-step manual process. It cannot be
  fully automated yet because Flux bootstrap requires interactive credential
  handling and the SPIFFE trust domain must be configured before cert-manager
  deploys.
- The SOPS age key must be securely transferred to the cluster out-of-band.
  It must never be committed to any repository.
- A cluster that loses its SOPS secret will fail to reconcile SOPS-encrypted
  manifests until the secret is restored.
- Cluster lifecycle (provisioning and decommissioning) must be coordinated
  with the Crossplane control plane to avoid orphaned AWS resources.

## References

- [ADR-2: Bootstrapping a Flux-Enabled Kubernetes Cluster](0002-managing-a-consistent-development-environment.md)
- [ADR-3: Bootstrapping the Crossplane Controlplane Cluster](0003-bootstrapping-the-crossplane-controlplane-cluster.md)
- [ADR-7: Crossplane Composition for ExternalDNS and CertManager IAM Roles Anywhere](0007-crossplane-composition-for-externaldns-and-certmanager-iam-roles-anywhere.md)
- [ADR-16: SPIFFE Trust Domain Configuration per Cluster](0016-spiffe-trust-domain-configuration-per-cluster.md)
- [FluxCD: Bootstrap](https://fluxcd.io/flux/installation/bootstrap/)
