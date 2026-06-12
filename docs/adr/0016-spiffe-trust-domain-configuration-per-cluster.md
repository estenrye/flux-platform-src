# 16. SPIFFE Trust Domain Configuration per Cluster

Date: 2026-06-10

## Status

Accepted

## Context

ADR-7 Decision 6 requires that every cluster using a shared IAM Roles Anywhere
trust anchor must be configured with a unique SPIFFE trust domain. This ADR
documents the implementation details for that requirement.

The default SPIFFE trust domain for Kubernetes workloads is `cluster.local`.
When multiple clusters share a trust anchor (Patterns B, C, D in ADR-7), all
clusters using `cluster.local` produce identical SPIFFE URIs — for example,
`spiffe://cluster.local/ns/external-dns/sa/external-dns`. IAM Roles Anywhere
validates only that a certificate chains to the trusted root CA; it does not
identify which cluster's intermediate CA signed it. This means a workload on
any cluster could impersonate a workload on any other cluster in the fleet.

## Decision

Every cluster must be configured with a unique SPIFFE trust domain before
cert-manager-spiffe-csi-driver is deployed. The trust domain is derived from
the cluster's `XDelegatedHostedZoneAWS` claim:

```
trustDomain = <spec.subdomain>.<resolvedZoneName>
```

For example, a claim with `spec.subdomain: crossplane` and resolved zone name
`rye.ninja` produces `trustDomain: crossplane.rye.ninja`.

This value is surfaced in `XDelegatedHostedZoneAWS.status.trustDomain` after
the claim reconciles.

### Configuring the trust domain

Set the trust domain on `cert-manager-spiffe-csi-driver` via its Helm values:

```yaml
# In the helmCharts values for cert-manager-spiffe-csi-driver:
app:
  trustDomain: crossplane.rye.ninja  # must match XDelegatedHostedZoneAWS.status.trustDomain
```

This value must be set before or at the same time as `cert-manager-spiffe-csi-driver`
is first deployed. Changing it after deployment requires restarting all pods
that have a SPIFFE SVID mounted, because the CSI driver re-issues all
certificates with the new trust domain on restart.

### Verification

After configuring, verify that SVIDs issued to pods use the correct trust domain:

```bash
# On the workload cluster, inspect a mounted SPIFFE certificate
kubectl exec -n <namespace> <pod-name> -- \
  openssl x509 -in /var/run/secrets/spiffe.io/tls.crt -text -noout \
  | grep URI
```

Expected output:
```
URI:spiffe://crossplane.rye.ninja/ns/<namespace>/sa/<service-account>
```

Verify that the trust domain in the certificate matches the URIs in the IAM
role trust policy:

```bash
aws iam get-role --role-name <role-name> \
  --query 'Role.AssumeRolePolicyDocument' \
  | jq '.Statement[].Condition.StringEquals["aws:PrincipalTag/x509SAN/URI"]'
```

Both values must match exactly.

### Prohibited configuration

The value `cluster.local` is prohibited for any cluster participating in a
shared trust anchor design (Patterns B, C, or D in ADR-7). CI linting does
not currently enforce this automatically — it is a manual review requirement
for new cluster additions.

## Consequences

- Every new workload cluster requires a corresponding `XDelegatedHostedZoneAWS`
  claim to exist and be Ready before the SPIFFE trust domain can be derived.
  This creates a dependency: Crossplane must reconcile the claim before
  cert-manager-spiffe-csi-driver is fully configured.
- If the trust domain is changed after initial deployment, all workloads must
  be restarted to receive new certificates. This is a brief, rolling operation
  but requires coordination with ExternalDNS and cert-manager to avoid DNS
  or certificate issuance gaps.
- The trust domain value is implicitly tied to the cluster's DNS subdomain.
  Renaming the cluster's subdomain requires a trust domain migration, which
  also requires updating IAM role trust policies.

## References

- [ADR-5: Using cert-manager to issue SPIFFE X.509 SVID Certificates](0005-using-cert-manager-to-issue-spiffe-x-509-svid-certificates-for-iam-access-roles-anywhere.md)
- [ADR-7: Crossplane Composition for ExternalDNS and CertManager IAM Roles Anywhere — Decision 6](0007-crossplane-composition-for-externaldns-and-certmanager-iam-roles-anywhere.md)
- [ADR-14: Workload Cluster Bootstrap and Lifecycle](0014-workload-cluster-bootstrap-and-lifecycle.md)
- [cert-manager SPIFFE CSI Driver: trust domain configuration](https://cert-manager.io/docs/usage/csi-driver-spiffe/)
- [SPIFFE specification: Trust Domain](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/#trust-domain)
