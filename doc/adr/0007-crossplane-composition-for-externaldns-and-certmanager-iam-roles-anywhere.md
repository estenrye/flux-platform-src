# 7. Crossplane Composition for ExternalDNS and CertManager IAM Roles Anywhere

Date: 2026-05-28

## Status

Accepted

## Context

### Goal

AWS IAM Roles Anywhere is a service that allows workloads running outside
of AWS to securely access AWS resources using IAM roles. This is particularly
useful for applications that need to interact with AWS services but are
not hosted within the AWS environment.

ExternalDNS and CertManager are two popular Kubernetes add-ons that manage
DNS records and TLS certificates, respectively. Both of these add-ons
require access to AWS resources to function properly. By using Crossplane
Composition, we can create a reusable and modular infrastructure definition
that allows ExternalDNS and CertManager to securely access AWS resources
using IAM Roles Anywhere. This approach will enable us to manage the necessary
IAM roles and permissions in a consistent and scalable manner, while also
ensuring that our applications can securely interact with AWS services
regardless of where they are hosted.

We need to build a composition that provisions the necessary IAM permissions
and trust relationships for ExternalDNS and CertManager to securely access
AWS resources using IAM Roles Anywhere.  This will involve provisioning the
necessary trust anchors, profiles, IAM roles and policies that are
required for the IAM Roles Anywhere trust relationship to function properly
and grant the necessary permissions to ExternalDNS and CertManager.

This composition will be deployed along side the
[XDelegatedHostedZoneAWS](applications/crossplane-resources/delegated-hosted-zone-aws)
composition that provisions the necessary AWS and
Cloudflare resources required for AWS Route53 to provide DNS services for a subdomain
that is delegated from Cloudflare to AWS Route53.  ExternalDNS and CertManager will
need permission to securely access the delegated hosted zone in AWS Route53, which is
provisioned by the XDelegatedHostedZoneAWS composition, in order to manage DNS records
and TLS certificates for the subdomain.

IAM permissions for ExternalDNS to access Route53 hosted zones are documented [here](https://raw.githubusercontent.com/kubernetes-sigs/external-dns/refs/heads/master/docs/tutorials/aws.md), and IAM permissions for CertManager to access Route53 hosted zones are documented [here](https://cert-manager.io/docs/configuration/acme/dns01/route53/).

The Composistion should consider Crossplane Resources where possible to provision the necessary AWS resources, which may include the following:
- [Role](https://marketplace.upbound.io/providers/upbound/provider-aws-iam/v2.5.4/resources/iam.aws.m.upbound.io/Role/v1beta1)
- [Policy](https://marketplace.upbound.io/providers/upbound/provider-aws-iam/v2.5.4/resources/iam.aws.m.upbound.io/Policy/v1beta1)
- [RolePolicyAttachment](https://marketplace.upbound.io/providers/upbound/provider-aws-iam/v2.5.4/resources/iam.aws.m.upbound.io/RolePolicyAttachment/v1beta1)
- [Profile](https://marketplace.upbound.io/providers/upbound/provider-aws-rolesanywhere/v2.5.4/resources/rolesanywhere.aws.m.upbound.io/Profile/v1beta1)

The aws terraform provider provides support for configuring trust anchor and profile resources
- [aws_iam_rolesanywhere_trust_anchor](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_rolesanywhere_trust_anchor)
  - source:
      source_type: "CERTIFCATE_BUNDLE"
      source_data:
        x509_certificate_data: |
            -----BEGIN CERTIFICATE-----
            ...
            -----END CERTIFICATE-----
- [aws_iam_rolesanywhere_profile](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rolesanywhere_profile)
- [aws_iam_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role)
- [aws_iam_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy)
- [aws_iam_role_policy_attachment](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment)


Example terraform code for provisioning the necessary trust anchor and profile resources for IAM Roles Anywhere is shown below:

```hcl
resource "aws_rolesanywhere_trust_anchor" "test" {
  name = "example"
  source {
    source_type = "CERTIFICATE_BUNDLE"
    source_data {
      x509_certificate_data = <<EOF
      -----BEGIN CERTIFICATE-----
      ...
      -----END CERTIFICATE-----
      EOF
    }
    source_type = "AWS_ACM_PCA"
  }
}

resource "aws_iam_policy" "ExternalDNSRoute53Access" {
  name        = "AllowExternalDNSRoute53Access"
  path        = "/"
  description = "Allow ExternalDNS to manage DNS records in one delegated hosted zone"

  # Terraform's "jsonencode" function converts a
  # Terraform expression result to valid JSON syntax.
  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
          "route53:ListTagsForResources"
        ],
        "Resource": [
          "arn:aws:route53:::hostedzone/${var.delegated_hosted_zone_id}"
        ],
        "Condition": {
          "ForAllValues:StringLike": {
            "route53:ChangeResourceRecordSetsActions": ["CREATE", "UPSERT", "DELETE"],
            "route53:ChangeResourceRecordSetsRecordTypes": ["A", "AAAA", "CNAME", "TXT"]
          }
        }
      }
    ]
  })
}

resource "aws_iam_role" "ExternalDNS" {
  name = "ExternalDNS"
  path = "/"

  assume_role_policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "rolesanywhere.amazonaws.com"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:SetSourceIdentity",
                "sts:TagSession"
            ],
            "Condition": {
                "StringEquals": {
                    "aws:PrincipalTag/x509SAN/URI": "spiffe://cluster.local/ns/external-dns/sa/external-dns"
                }
            }
        }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ExternalDNS-attach" {
  role       = aws_iam_role.ExternalDNS.name
  policy_arn = aws_iam_policy.ExternalDNSRoute53Access.arn
}

resource "aws_rolesanywhere_profile" "test" {
  name      = "example"
  role_arns = [aws_iam_role.ExternalDNS.arn]
}
```

An example of how terraform can be used to provision an AWS Roles anywhere trust anchor, profile and role is shown below:


Cert-manager and ExternalDNS will be modified to use the SPIFFE CSI driver to obtain SPIFFE X.509 SVID certificate.
A side-car will be deployed in cert-manager and ExternalDNS that implements the AWS IAM Roles Anywhere credential helper, which will allow cert-manager and ExternalDNS to securely access AWS resources using IAM Roles Anywhere by presenting the SPIFFE X.509 SVID certificate to the credential helper, which will then exchange the certificate for temporary AWS credentials that can be used to access AWS resources.

An example of the type of patch that will be applied to add SPIFFE CSI driver support and the AWS IAM Roles Anywhere credential helper to cert-manager and ExternalDNS is shown below:

```yaml
    spec:
      selector:
        matchLabels:
          app: upbound-provider-aws-route53
      template:
        metadata:
          labels:
            app: upbound-provider-aws-route53
        spec:
          securityContext:
            runAsGroup: 2000
            runAsNonRoot: true
            runAsUser: 2000
            fsGroup: 2000
          serviceAccountName: aws-route53-dns-provider
          containers:
            - name: package-runtime
              env:
                - name: AWS_REGION
                  value: us-east-2
                - name: AWS_EC2_METADATA_SERVICE_ENDPOINT
                  value: http://localhost:9911
            - name: aws-signing-helper
              image: public.ecr.aws/rolesanywhere/credential-helper:1.8.1-2026.04.09.16.01
              command: 
                - aws_signing_helper
                - serve
                - --port
                - "9911"
                - --debug
                - --certificate
                - /var/run/secrets/spiffe.io/tls.crt
                - --private-key
                - /var/run/secrets/spiffe.io/tls.key
                - --trust-anchor-arn
                - arn:aws:rolesanywhere:us-east-2:832767337984:trust-anchor/1433b5ab-1a7a-4134-9d84-baa79f94d093
                - --profile-arn
                - arn:aws:rolesanywhere:us-east-2:832767337984:profile/cbe4ff4a-87e4-4635-a08e-ace27111b830
                - --role-arn
                - arn:aws:iam::832767337984:role/crossplane-provider-dns-admin
              imagePullPolicy: IfNotPresent
              ports:
                - containerPort: 9911
                  name: imdsv2
                  protocol: TCP
              volumeMounts:
                - mountPath: "/var/run/secrets/spiffe.io"
                  name: spiffe
          volumes:
            - name: spiffe
              csi:
                driver: spiffe.csi.cert-manager.io
                readOnly: true
```

### Dependencies

The first component of this solution is provided by 
[cert-manager](../../applications/cert-manager/base/), which is a Kubernetes
add-on that automates the management and issuance of TLS certificates.
Cert-manager can be used to provision the trust anchor certificate that is
required for IAM Roles Anywhere to establish a trust relationship with the
workloads running in our Kubernetes clusters.

The second component of this solution is provided by the
[cert-manager-spiffe-issuer](../../applications/cert-manager-spiffe-issuer/base/) module, which is a cert-manager issuer that uses the SPIFFE CSI driver to issue SPIFFE X.509 SVID certificates to workloads running in the cluster.

The third component of this solution is provided by the[approver-policy](../../applications/cert-manager-approver-policy/base/) controller, which can be used to implement approval policies for `CertificateRequest` resources in the cluster.  

The fourth component of this solution is the [cert-manager-trust-manager](../../applications/cert-manager-trust-manager/base/) controller, which can be used to implement trust bundles for certificate authorities in the cluster.  This is important for managing the trust relationships between the workloads in the cluster.

The last component of this solution is the [cert-manager-spiffe-csi-driver](../../applications/cert-manager-spiffe-csi-driver/base) controller, which can be used to implement the SPIFFE CSI driver for cert-manager.  This allows workloads running in the cluster to obtain SPIFFE X.509 SVID certificates that are signed by the intermediate CA certificate provisioned by the `cert-manager-spiffe-issuer` module, which is necessary for the SPIFFE CSI driver to function properly and allow workloads to securely access AWS resources using IAM Roles Anywhere.

### Self-Signed ClusterIssuer

Every Kubernetes cluster in the fleet will have a trust root provisioned
using the [cert-manager-spiffe-issuer](../../applications/cert-manager-spiffe-issuer/base)
module.

A [ClusterIssuer](https://cert-manager.io/docs/reference/api-docs/#cert-manager.io/v1.ClusterIssuer)
resource named [selfsigned](../../applications/cert-manager/base/resources/selfsigned.clusterissuer.yaml)
is used to issue a self-signed certificate that serves as the trust anchor for the IAM Roles Anywhere trust relationship.

The `selfsigned` `ClusterIssuer` is a self-signed issuer, which means that it will generate a self-signed certificate
and private key when it is created.  The self-signed certificate will be used as the trust anchor for the IAM Roles
Anywhere trust relationship, and the private key will be used to sign intermediate certificates that are issued to
workloads running in the cluster.

### Cluster Root Trust Anchor Certificate

The `cert-manager-spiffe-issuer` module provisions a self-signed root
[Certificate](https://cert-manager.io/docs/reference/api-docs/#cert-manager.io/v1.Certificate) resource in the
[cert-manager](../../applications/cert-manager/base/resources/namespace.yaml) namespace named
[csi-driver-spiffe-ca](../../applications/cert-manager-spiffe-issuer/base/resources/csi-driver-spiffe-ca.certificate.yaml).  

Cert-manager will provision the corresponding private key and certificate in a `Secret` resource named `csi-driver-spiffe-ca` in the `cert-manager` namespace.  The trust anchor certificate is stored in the `.data.tls\.crt` field of the
`Secret` resource, which is base64-encoded.

This certificate will be used as the trust anchor for the IAM Roles Anywhere trust relationship.  The
following bash command can be used to retrieve the trust anchor certificate from the cluster:

```bash
kubectl -n cert-manager get secret csi-driver-spiffe-ca -o jsonpath='{.data.tls\.crt}' | base64 --decode
```

A Human readable version of the trust anchor certificate can be obtained by running the following command:

```bash
kubectl -n cert-manager get secret csi-driver-spiffe-ca -o jsonpath='{.data.tls\.crt}' | base64 --decode | openssl x509 -text -noout
```

### Intermediate Certificate Authority for Workloads in the Cluster

The `cert-manager-spiffe-issuer` module provisions a `ClusterIssuer` resource named
[csi-driver-spiffe-issuer](../../applications/cert-manager-spiffe-issuer/base/resources/csi-driver-spiffe-ca.clusterissuer.yaml)
that uses the Root Trust Anchor Certificate and Private Key in the `csi-driver-spiffe-ca` `Secret` resource
provisioned by the [csi-driver-spiffe-ca](../../applications/cert-manager-spiffe-issuer/base/resources/csi-driver-spiffe-ca.certificate.yaml) `Certificate` resource.

The `csi-driver-spiffe-issuer` `ClusterIssuer` resource acts as an intermediate certificate authority (CA) that is signed by the root trust anchor certificate.  The `ClusterIssuer` can then be used to issue certificates for workloads running in the cluster, and these certificates will be trusted by the IAM Roles Anywhere trust relationship because the Intermediate CA certificate is signed by the root trust anchor certificate.  

This allows workloads running in the cluster to securely access AWS resources using IAM Roles Anywhere without needing to manage their own trust anchor certificates.  The root trust anchor certificate serves as the foundation of the trust relationship between the workloads in the cluster and AWS.

Under the hood, the cert-manager SPIFFE CSI driver will use the
[CertificateRequest](https://cert-manager.io/docs/reference/api-docs/#cert-manager.io/v1.CertificateRequest) resource
to request certificates from the `csi-driver-spiffe-issuer` `ClusterIssuer` on behalf of workloads running in the cluster.
The `CertificateRequest` resource will specify the desired properties of the certificate, such as the URI SAN that is
required for the SPIFFE CSI driver to function properly.

By default, `CertificateRequest` resources require approval before they can be issued, which provides an additional layer of security and control over the issuance of certificates in the cluster.  The
[approver-policy](../../applications/cert-manager-approver-policy/base) controller can be used to implement approval policies
for `CertificateRequest` resources in the cluster, allowing us to define rules for when certificate requests should be
automatically approved or require manual approval.

A `CertificateRequestPolicy` resource named [csi-driver-spiffe-issuer-policy](../../applications/cert-manager-spiffe-issuer/base/resources/csi-driver-spiffe-ca.certificaterequestpolicy.yaml) is provisioned to allow the SPIFFE CSI driver to automatically approve `CertificateRequest` resources that are created by the SPIFFE CSI driver for workloads running in the cluster.  This ensures that workloads can obtain the necessary certificates to securely access AWS resources using IAM Roles Anywhere without requiring manual intervention for each certificate request.

### Giving cert-manager permissions to use the CertificateRequestPolicy

The `cert-manager-spiffe-issuer` module provisions a `Role` resource named
[cert-manager-spiffe-issuer-policy](../../applications/cert-manager-spiffe-issuer/base/resources/csi-driver-spiffe-ca.clusterrole.yaml) and a `RoleBinding` resource named
[cert-manager-spiffe-issuer-policy](../../applications/cert-manager-spiffe-issuer/base/resources/csi-driver-spiffe-ca.clusterrolebinding.yaml) to give the cert-manager controller permissions to use the `CertificateRequestPolicy` resource that is provisioned in the cluster.  This allows cert-manager to automatically approve `CertificateRequest` resources that are created by the SPIFFE CSI driver for workloads running in the cluster, which is necessary for the SPIFFE CSI driver to function properly and allow workloads to securely access AWS resources using IAM Roles Anywhere.


## Decision

We will implement IAM Roles Anywhere for ExternalDNS and CertManager using
Crossplane-managed AWS resources and SPIFFE identities issued by cert-manager.

The implementation will follow these decisions:

1. Least privilege by default
   - IAM policies for ExternalDNS and CertManager will be scoped to the
     delegated hosted zone ARN only, not all hosted zones in the account.
   - Route53 `ListHostedZones` will not be required for steady-state
     operation when the hosted zone identifier is known.

2. Per-workload permission scoping, enforced by SPIFFE URI
   - ExternalDNS and CertManager require different Route53 action scopes:
     cert-manager restricts `ChangeResourceRecordSets` to TXT records only
     (ACME DNS01 challenges), while ExternalDNS requires A, AAAA, CNAME,
     and TXT for full DNS lifecycle management.
   - Two role-layout options are supported; the choice is made at composition
     time (see "IAM policy design" in Limitations):
       a. Separate roles (high-isolation environments): one IAM Role, Policy,
          and Roles Anywhere Profile per workload per cluster.
       b. ABAC single role (quota-conscious deployments): one shared IAM Role
          and Profile per cluster, with a single policy whose statements are
          conditioned on `aws:PrincipalTag/x509SAN/URI` to enforce per-workload
          action boundaries.
   - In both options, neither workload session can access the other workload's
     permitted actions. The SPIFFE URI SAN is the authoritative identity
     boundary.

3. Crossplane is the source of truth for AWS identity resources
   - The composition will manage Role, Policy, RolePolicyAttachment, Profile,
     and TrustAnchor.
   - The delegated hosted zone identifier from `XDelegatedHostedZoneAWS`
     status will be used to template zone-scoped IAM policy documents.

4. Trust anchor distribution is API-based with verification
   - We will build a service that publishes the trust anchor certificate from
     the workload cluster.
   - The service must support strong authentication and response integrity
     verification before the crossplane cluster can consume the certificate.

5. Certificate lifetime strategy
   - We will evaluate a 5-year trust anchor certificate duration against
     security and operations trade-offs before changing defaults.
   - No duration change will be merged without a documented rotation and
     emergency rollover runbook.

6. SPIFFE trust domain uniqueness for shared trust anchor patterns
   - Clusters using Pattern B, C, or D must configure a cluster-unique SPIFFE
     trust domain. With a shared trust anchor, IAM Roles Anywhere only validates
     that a certificate chains to the trusted root; it does not record which
     cluster's intermediate CA signed it. If all clusters use the default
     `cluster.local` trust domain, their SPIFFE URIs are identical and IAM
     role trust policy conditions cannot distinguish between clusters.
   - The default trust domain `cluster.local` is prohibited for any cluster
     participating in a shared trust anchor design.
   - The trust domain is derived from `XDelegatedHostedZoneAWS` as
     `${spec.subdomain}.${spec.zoneName}` and surfaced in `status.trustDomain`.
     The IAM Roles Anywhere composition consumes this value via cross-resource
     reference — no additional trust domain input is required.
   - Example: `subdomain: crossplane`, `zoneName: rye.ninja` → trust domain
     `crossplane.rye.ninja` → SPIFFE URI
     `spiffe://crossplane.rye.ninja/ns/external-dns/sa/external-dns`.
   - DNS names are globally unique by property, satisfying the uniqueness
     requirement automatically without a separate cluster-identity field.
   - Pattern A is exempt: the per-cluster trust anchor provides cluster
     isolation independently of the trust domain value. Unique trust domains
     are still recommended for operational clarity.

## Limitations

The following AWS service quotas and limits constrain the long-term scaling
shape of this design. Values are defaults unless otherwise noted.

### IAM Roles Anywhere object and API limits (per account, per Region)

- Trust anchors: 50
- Profiles: 250
- Roles per profile: 250
- Certificates per trust anchor: 2 (not adjustable)
- CRLs per trust anchor: 2 (not adjustable)
- CreateSession rate: 10 TPS (adjustable)
- Control-plane API rate buckets (for trust anchor/profile/subject/tagging/CRL APIs): 1 TPS each combined bucket (adjustable)

### IAM limits that affect this implementation

- Roles per account: 1000 default, up to 10000
- Customer managed policies per account: 1500 default, up to 10000
- Managed policies attached per role: 10 default, up to 25
- Role trust policy length: 2048 characters default, up to 8192
- Managed policy document size: 6144 characters
- Aggregate inline policy size on a role: 10240 characters

### Practical scaling implications

- Trust anchors are typically the first hard object limit encountered in a strict per-cluster trust model.
- Profiles are typically the next limiting object when each workload identity receives a dedicated profile.
- Shared-role designs reduce object count but increase trust-policy complexity and blast radius.
- CreateSession throttling can become a runtime bottleneck during large synchronized restarts.

### Pattern A: Per-cluster trust anchor with per-workload role/profile

Summary:
- Each cluster has its own trust anchor.
- Each workload identity (ExternalDNS and CertManager) has a dedicated IAM Role, Policy, and Roles Anywhere Profile.

Pros:
- Strongest isolation boundary between clusters.
- Clear least-privilege and ownership boundaries.
- Straightforward incident containment and cluster-specific revocation.

Cons:
- Highest object growth rate.
- Trust anchors (50/account/Region) are the first scaling bottleneck.
- More reconciliation objects and operational overhead.

When to choose:
- High-assurance environments with strict tenant or cluster isolation requirements.
- Environments where independent emergency rollback per cluster is mandatory.

Quota shape:
- Roughly linear growth per cluster across trust anchors, profiles, roles, and policies.
- With two workload identities per cluster, trust anchors usually cap before IAM role/policy quotas.

### Pattern B: Shared trust anchor per environment with per-cluster role/profile

Summary:
- One trust anchor is shared by multiple clusters in an environment (for example, dev or prod).
- Each cluster/workload identity still gets dedicated IAM Role, Policy, and Profile.

Pros:
- Significantly reduces trust-anchor object pressure.
- Retains role-level least privilege for hosted-zone access.
- Better account-level scalability while preserving workload separation.

Cons:
- Shared trust root increases blast radius if anchor material is compromised.
- Rotation and rollover procedures become more coordination-heavy.
- Requires tighter controls on SPIFFE identity issuance and verification.
- **Requires cluster-unique SPIFFE trust domains.** All clusters sharing this
  trust anchor must be configured with distinct trust domains (not `cluster.local`)
  to prevent cross-cluster role assumption via identical SPIFFE URI conditions.
  See "Trust domain uniqueness requirement" in the IAM policy design section.

When to choose:
- Platform environments targeting moderate/high cluster counts in a single account/Region.
- Teams that can operate disciplined trust-anchor lifecycle management.

Quota shape:
- Trust anchors grow by environment, while profiles/roles/policies still grow by cluster/workload.
- Profile quotas may become the first object bottleneck after trust anchors are flattened.

### Pattern C: Single trust anchor (crossplane root CA) with per-cluster intermediate CA — centrally issued

Summary:
- The crossplane cluster hosts the root CA (`csi-driver-spiffe-ca`) as the single IAM Roles Anywhere trust anchor.
- When provisioning a workload cluster, Crossplane issues an intermediate CA `Certificate` resource against the root CA
  on the crossplane cluster.
- The resulting intermediate CA cert and private key Secret is distributed to the workload cluster via
  External Secrets Operator or a Crossplane managed Kubernetes Secret.
- On the workload cluster, `cert-manager-spiffe-issuer` uses the delivered intermediate CA instead of a self-signed root.
- SVIDs issued on the workload cluster chain as: root CA → intermediate CA → SVID.
- IAM Roles Anywhere validates the full chain against the single trust anchor (root CA).

Pros:
- Single trust anchor eliminates the trust-anchor quota bottleneck entirely.
- Profiles (250 limit) become the first constraint, supporting ~125 clusters before quota increase is needed.
- Cluster-level revocation is still possible by revoking the intermediate CA.
- Simpler to implement with Crossplane — no bootstrap channel required between clusters.

Cons:
- Intermediate CA private key is generated on the crossplane cluster and transmitted to the workload cluster.
- The private key exists in two places (crossplane cluster Secret and workload cluster Secret), increasing the attack surface.
- Compromise of the root CA private key on the crossplane cluster compromises all workload clusters simultaneously.
- Rotation and revocation procedures must account for all clusters sharing the root trust.
- CRL support is limited to 2 CRLs per trust anchor (not adjustable); OCSP must be evaluated for timely revocation.

Key risks:
- Centralized key generation and distribution is the primary security concern.
- A decommissioned cluster whose intermediate CA is not explicitly revoked retains a valid credential path until
  the intermediate CA expires.

When to choose:
- Platform environments prioritizing operational simplicity and scale over strict key hygiene.
- Teams that accept centralized key management and have strong Secret encryption and access controls in place.

### Pattern D: Single trust anchor (crossplane root CA) with per-cluster intermediate CA — CSR-based

Summary:
- The crossplane cluster hosts the root CA as the single IAM Roles Anywhere trust anchor, same as Pattern C.
- The workload cluster generates its own intermediate CA keypair locally and submits a
  `CertificateSigningRequest` to the crossplane cluster for signing.
- The crossplane cluster (or a dedicated controller) signs the CSR against the root CA and returns only the
  signed certificate — the private key never leaves the workload cluster.
- On the workload cluster, `cert-manager-spiffe-issuer` uses the locally generated keypair and the
  signed intermediate CA certificate.
- SVIDs chain as: root CA → intermediate CA → SVID, same as Pattern C.

Pros:
- Strongest key hygiene: the intermediate CA private key is generated and stays on the workload cluster.
- Compromise of the crossplane cluster does not expose workload cluster private keys.
- Single trust anchor retains all quota benefits of Pattern C.
- Cluster-level revocation is still possible by revoking the intermediate CA certificate.

Cons:
- Requires a bootstrap channel between the workload cluster and the crossplane cluster before cert-manager is
  fully operational — a chicken-and-egg bootstrapping problem.
- More complex to implement: needs a controller or workflow to accept CSRs from workload clusters, verify
  their identity, sign with the root CA, and return the certificate.
- The bootstrap identity used to authenticate the CSR request must itself be secured independently.
- Higher operational complexity for the signing workflow and its failure modes.

Key risks:
- The bootstrapping identity and channel are a new trust root that must be carefully secured.
- If the signing workflow is unavailable, new workload clusters cannot become operational.

When to choose:
- High-assurance environments where private key hygiene is a hard requirement.
- Teams willing to invest in a robust bootstrap and signing workflow.

#### Pattern D deep-dive: cert-manager alone vs. step-ca

**Can cert-manager implement Pattern D without additional tooling?**

No. cert-manager is an in-cluster operator. Its `CertificateRequest` and `Certificate` resources are cluster-scoped
and have no native mechanism for cross-cluster CSR submission or signing. To implement Pattern D with cert-manager
alone, a custom external issuer controller would need to be written to:
- accept CSRs from workload clusters over a secure channel
- authenticate the identity of the requesting cluster before signing
- return only the signed certificate to the workload cluster

In addition, cert-manager does not generate Certificate Revocation Lists (CRLs) and has no built-in OCSP
responder. Implementing CRL-based revocation of intermediate CAs would require entirely separate tooling. For
these reasons, cert-manager alone is not sufficient for Pattern D.

**step-ca as the signing authority**

[step-ca](https://github.com/smallstep/certificates) is a purpose-built certificate authority server with native
support for the cross-cluster signing flow Pattern D requires. Key capabilities relevant to this design:

- **X5C provisioner**: a client authenticates a CSR by presenting an existing X.509 certificate that chains to a
  root trusted by step-ca. Crossplane can issue a short-lived bootstrap certificate to a new workload cluster
  during provisioning; the cluster presents this certificate to step-ca to authenticate its CSR for the
  intermediate CA. The private key is generated on the workload cluster and the bootstrap certificate expires
  after use.
- **K8sSA provisioner**: a client authenticates using a Kubernetes ServiceAccount token. step-ca is configured
  with the public key of the workload cluster's K8s API server to validate the token. This removes the need for
  a separate bootstrap certificate, but the K8sSA token is effectively a bearer token and provides minimal
  constraint on the CSR subject — it requires careful policy configuration to prevent over-issuance.
- **Certificate templates**: step-ca uses Go templates to control the content of issued certificates. Templates
  can enforce `isCA: true`, `maxPathLen: 0`, desired URI SANs, and CRL distribution point (CDP) extensions on
  intermediate CA certificates.
- **Built-in CRL server**: step-ca hosts a CRL at the `/1.0/crl` endpoint. The CRL is updated on every
  revocation. CDPs are embedded in issued certificates via templates, pointing to this endpoint.
- **cert-manager integration**: the [step-issuer](https://github.com/smallstep/step-issuer) external issuer
  allows cert-manager to remain the in-cluster certificate lifecycle manager while step-ca acts as the signing
  authority. On the workload cluster, cert-manager requests the intermediate CA certificate from step-ca via
  step-issuer; the keypair is generated locally by cert-manager.

**Recommended bootstrap flow for Pattern D using step-ca X5C provisioner**

```
Cluster provisioning (Crossplane)
  1. Crossplane issues a short-lived (e.g. 1h) bootstrap certificate to the new
     workload cluster, signed by the root CA. This cert contains the cluster's
     unique identity as a URI SAN or CN.
  2. Crossplane stores the bootstrap cert and configures step-ca with an X5C
     provisioner that trusts the root CA.

Workload cluster bootstrap (cert-manager + step-issuer)
  3. cert-manager generates an intermediate CA keypair on the workload cluster.
     The private key never leaves the cluster.
  4. cert-manager submits a CertificateRequest to step-issuer, including the CSR
     and the bootstrap certificate as the X5C authentication token.
  5. step-ca validates:
       a. the X5C certificate chains to the trusted root CA
       b. the X5C certificate is within its validity period
       c. the CSR subject/SAN matches the expected cluster identity (via template
          policy)
  6. step-ca signs the intermediate CA certificate with the CDP embedded and
     returns only the signed certificate.
  7. cert-manager-spiffe-issuer uses the signed intermediate CA + local keypair
     to issue SVIDs to workloads.
  8. The bootstrap certificate expires and is discarded.
```

**CRL distribution and IAM Roles Anywhere revocation**

To revoke a workload cluster's intermediate CA:
1. Run `step ca revoke <serial>` on step-ca. The CRL at `/1.0/crl` is immediately updated.
2. IAM Roles Anywhere checks CRL distribution points embedded in the intermediate CA certificate during
   session validation if the trust anchor has CRL checking enabled.

Two mechanisms exist for CRL delivery to IAM Roles Anywhere:

- **CDP-based checking (preferred)**: the intermediate CA certificate contains a `crlDistributionPoints`
  extension pointing to step-ca's `/1.0/crl` HTTP endpoint. IAM Roles Anywhere fetches and caches this CRL
  when validating certificate chains. **Requirement**: step-ca's CRL endpoint must be reachable from AWS over
  HTTP. This typically means exposing step-ca's insecure address (CRL is served over HTTP by design, as CDPs
  must be unauthenticated) via a load balancer or ingress.
- **Imported CRL (fallback)**: IAM Roles Anywhere allows importing a CRL file directly to a trust anchor
  (limit: 2 CRLs per trust anchor, not adjustable). A controller can watch step-ca for revocation events,
  fetch the updated CRL, and re-import it to IAM Roles Anywhere via the `ImportCrl` / `UpdateCrl` API. This
  avoids exposing step-ca to the internet but introduces a sync delay between revocation and enforcement.

Key operational notes:
- CRL checking in IAM Roles Anywhere is opt-in per trust anchor and must be explicitly enabled.
- CDP-based checking requires HTTP (not HTTPS) access to the CRL endpoint per RFC 5280.
- The 2 CRL slots per trust anchor limit applies to imported CRLs only; CDP-based checking is unlimited.
- OCSP is not available in step-ca open source; it is a commercial-only feature. CDP-based CRL is the
  recommended open source revocation mechanism.

**Summary: cert-manager alone vs. step-ca for Pattern D**

| Capability | cert-manager alone | step-ca + step-issuer |
|---|---|---|
| Cross-cluster CSR signing | Not supported natively | Native (X5C, K8sSA provisioners) |
| Key stays on workload cluster | Yes (with custom controller) | Yes (by design) |
| CRL generation | Not supported | Built-in (`/1.0/crl`) |
| CDP embedding in certs | Not supported | Via certificate templates |
| OCSP | Not supported | Commercial only |
| cert-manager integration | Native (in-cluster only) | Via step-issuer external issuer |
| Bootstrap complexity | Very high (custom controller needed) | Medium (X5C provisioner) |

**Conclusion**: step-ca with the X5C provisioner and step-issuer is the recommended implementation for Pattern D.
cert-manager remains the in-cluster lifecycle manager for SVIDs; step-ca handles intermediate CA issuance and
CRL generation on the crossplane cluster.

### IAM policy design: separate roles vs. ABAC single role

IAM Roles Anywhere sets the certificate's URI SAN as a session tag on the
temporary credentials it issues, exposed as `aws:PrincipalTag/x509SAN/URI`
during IAM policy condition evaluation. This allows a single policy document
to contain multiple statements each conditioned on a specific SPIFFE URI,
enforcing per-workload permission boundaries even when both workloads share
a single IAM role.

**Permission comparison between the two workloads:**

| Action | cert-manager | ExternalDNS | Resource scope |
|---|---|---|---|
| `route53:ChangeResourceRecordSets` | Yes — **TXT only** | Yes — A, AAAA, CNAME, TXT | `hostedzone/<id>` |
| `route53:ListResourceRecordSets` | Yes | Yes | `hostedzone/<id>` |
| `route53:GetChange` | Yes (change propagation polling) | No | `change/*` |
| `route53:ListHostedZonesByName` | Yes (zone discovery) | No | `*` |
| `route53:ListHostedZones` | No | Yes (zone discovery) | `*` |
| `route53:ListTagsForResources` | No | Yes (TXT ownership tracking) | `hostedzone/<id>` |

The record-type scope difference on `ChangeResourceRecordSets` is the key reason
a single unconditioned policy cannot cover both workloads without violating PoLP.
ABAC conditions resolve this within a single policy document.

#### Option A: Separate roles (high-isolation default)

Two IAM roles, two policies, two profiles per cluster. Each role's trust policy
restricts assumption to exactly one SPIFFE URI. A misconfigured SPIFFE CSI policy
that issues the wrong URI to a pod is rejected at role-assumption time.

#### Option B: ABAC single role (quota-efficient default)

One IAM role, one policy, one profile per cluster. The role trust policy lists
both SPIFFE URIs; IAM `StringEquals` with a list value evaluates as set membership
(matches if the tag equals any listed value). The single policy document contains
five statements, each conditioned on `aws:PrincipalTag/x509SAN/URI`.

The `sts:SetSourceIdentity` and `sts:TagSession` actions must remain in the
trust policy to allow IAM Roles Anywhere to stamp the session identity and tags;
ABAC conditions in the permission policy will not function without these.

**Shared role trust policy condition:**

```json
"Condition": {
  "StringEquals": {
    "aws:PrincipalTag/x509SAN/URI": [
      "spiffe://cluster.local/ns/cert-manager/sa/cert-manager",
      "spiffe://cluster.local/ns/external-dns/sa/external-dns"
    ]
  }
}
```

**Merged ABAC permission policy:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ExternalDNSRecordManagement",
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets",
        "route53:ListResourceRecordSets",
        "route53:ListTagsForResources"
      ],
      "Resource": "arn:aws:route53:::hostedzone/${var.delegated_hosted_zone_id}",
      "Condition": {
        "StringEquals": {
          "aws:PrincipalTag/x509SAN/URI":
            "spiffe://cluster.local/ns/external-dns/sa/external-dns"
        },
        "ForAllValues:StringLike": {
          "route53:ChangeResourceRecordSetsActions": ["CREATE", "UPSERT", "DELETE"],
          "route53:ChangeResourceRecordSetsRecordTypes": ["A", "AAAA", "CNAME", "TXT"]
        }
      }
    },
    {
      "Sid": "ExternalDNSZoneDiscovery",
      "Effect": "Allow",
      "Action": "route53:ListHostedZones",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:PrincipalTag/x509SAN/URI":
            "spiffe://cluster.local/ns/external-dns/sa/external-dns"
        }
      }
    },
    {
      "Sid": "CertManagerACMEDNS01",
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets",
        "route53:ListResourceRecordSets"
      ],
      "Resource": "arn:aws:route53:::hostedzone/${var.delegated_hosted_zone_id}",
      "Condition": {
        "StringEquals": {
          "aws:PrincipalTag/x509SAN/URI":
            "spiffe://cluster.local/ns/cert-manager/sa/cert-manager",
          "route53:ChangeResourceRecordSetsRecordTypes": ["TXT"]
        }
      }
    },
    {
      "Sid": "CertManagerChangePolling",
      "Effect": "Allow",
      "Action": "route53:GetChange",
      "Resource": "arn:aws:route53:::change/*",
      "Condition": {
        "StringEquals": {
          "aws:PrincipalTag/x509SAN/URI":
            "spiffe://cluster.local/ns/cert-manager/sa/cert-manager"
        }
      }
    },
    {
      "Sid": "CertManagerZoneDiscovery",
      "Effect": "Allow",
      "Action": "route53:ListHostedZonesByName",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:PrincipalTag/x509SAN/URI":
            "spiffe://cluster.local/ns/cert-manager/sa/cert-manager"
        }
      }
    }
  ]
}
```

**Trade-offs:**

| | Option A: Separate roles | Option B: ABAC single role |
|---|---|---|
| Roles per cluster | 2 | 1 |
| Policies per cluster | 2 | 1 |
| Profiles per cluster | 2 | 1 |
| PoLP boundary | Role assumption (strongest) | Policy statement condition |
| Misconfigured SPIFFE URI | Rejected at role assumption | Rejected at API authorization |
| CloudTrail attribution | Role name distinguishes workload | Must inspect `x509SAN/URI` session tag |
| Object count saving | Baseline | 50% reduction in roles, policies, profiles |

#### Trust domain uniqueness requirement for shared trust anchors

This requirement applies to **both** Option A and Option B when used with
Patterns B, C, or D — any design where multiple clusters share a trust anchor.

**The problem**: The default SPIFFE trust domain is `cluster.local`. All
clusters using this default produce identical SPIFFE URIs, for example
`spiffe://cluster.local/ns/external-dns/sa/external-dns`. With a shared
trust anchor, IAM Roles Anywhere validates only that the certificate chains
to the trusted root CA — it does not identify which cluster's intermediate
CA signed it. The IAM role trust policy condition then evaluates
`aws:PrincipalTag/x509SAN/URI`, which is the same value across all clusters.
A workload on any cluster in the fleet could present a valid certificate and
pass the condition check on any other cluster's IAM role.

**The fix**: Each cluster must be configured with a unique SPIFFE trust
domain via the `--trust-domain` flag on cert-manager-spiffe-csi-driver
(Helm value: `app.trustDomain`). The IAM Roles Anywhere Crossplane composition
must:

1. Read `XDelegatedHostedZoneAWS.status.trustDomain` via cross-resource reference.
2. Template it into the SPIFFE URI strings used in IAM role trust policy
   conditions and ABAC permission policy `aws:PrincipalTag/x509SAN/URI`
   condition values.

**Trust domain source**: `XDelegatedHostedZoneAWS.status.trustDomain` =
`${spec.subdomain}.${spec.zoneName}`

This value is computed by the composition and emitted as a status field. DNS
names are globally unique by property, so deriving the trust domain from the
delegated hosted zone domain satisfies the uniqueness requirement automatically
without a separate cluster-identity input.

For example, the claim with `subdomain: crossplane` and `zoneName: rye.ninja`
produces `status.trustDomain: crossplane.rye.ninja`, and therefore:

```
spiffe://crossplane.rye.ninja/ns/external-dns/sa/external-dns
spiffe://crossplane.rye.ninja/ns/cert-manager/sa/cert-manager
```

The role trust policy condition for this cluster becomes:

```json
"Condition": {
  "StringEquals": {
    "aws:PrincipalTag/x509SAN/URI": [
      "spiffe://crossplane.rye.ninja/ns/cert-manager/sa/cert-manager",
      "spiffe://crossplane.rye.ninja/ns/external-dns/sa/external-dns"
    ]
  }
}
```

**Pattern A exemption**: Each cluster has its own independent trust anchor;
IAM Roles Anywhere validates the full chain to that specific cluster's CA.
A certificate from another cluster cannot pass a different cluster's trust
anchor validation, so `cluster.local` does not create a cross-cluster
impersonation risk in Pattern A. Unique trust domains are still recommended
for operational consistency and forward compatibility if the design later
migrates to a shared trust anchor pattern.

### Trust anchor design comparison

| | Pattern A | Pattern B | Pattern C | Pattern D |
|---|---|---|---|---|
| Trust anchors | 1 per cluster | 1 per environment | **1 total** | **1 total** |
| Profiles (Option A) | 2 per cluster | 2 per cluster | 2 per cluster | 2 per cluster |
| Profiles (Option B ABAC) | 1 per cluster | 1 per cluster | 1 per cluster | 1 per cluster |
| Roles (Option A) | 2 per cluster | 2 per cluster | 2 per cluster | 2 per cluster |
| Roles (Option B ABAC) | 1 per cluster | 1 per cluster | 1 per cluster | 1 per cluster |
| Blast radius | Per cluster | Per environment | **All clusters** | **All clusters** |
| Key hygiene | Strong (self-signed per cluster) | Strong | Weaker (central key gen) | **Strongest (key never leaves cluster)** |
| Operational complexity | Low | Low | Medium | High |
| First quota bottleneck (Option A) | Trust anchors (50) | Trust anchors (50) | Profiles (250) | Profiles (250) |
| First quota bottleneck (Option B ABAC) | Trust anchors (50) | Trust anchors (50) | Profiles (250, doubled capacity) | Profiles (250, doubled capacity) |

### Recommended default

- Default to Pattern B for platform scale.
- Use the ABAC single-role option (Option B) for new compositions to halve IAM object count per cluster and double effective profile capacity before hitting the 250-profile quota.
- Escalate specific clusters to Option A (separate roles) where role-assumption-time identity rejection is a hard requirement.
- Escalate specific clusters to Pattern A where stricter cluster-level trust isolation requirements justify the additional trust-anchor object overhead.
- Adopt Pattern C or D if trust-anchor quota pressure is encountered or a single-root-of-trust design is required.
- Prefer Pattern D over Pattern C when adopting the single trust anchor model, accepting the additional bootstrap complexity in exchange for stronger key hygiene.
- Implement Pattern D using step-ca (X5C provisioner) + step-issuer on the crossplane cluster, with cert-manager as the in-cluster lifecycle manager on workload clusters.

References:
- IAM quotas: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html
- IAM Roles Anywhere quotas: https://docs.aws.amazon.com/rolesanywhere/latest/userguide/quotas.html
- step-ca (smallstep): https://github.com/smallstep/certificates
- step-ca provisioners: https://smallstep.com/docs/step-ca/provisioners/
- step-issuer (cert-manager external issuer for step-ca): https://github.com/smallstep/step-issuer
- step-ca CRL / active revocation: https://smallstep.com/docs/step-ca/certificate-authority-server-production/#consider-active-revocation

## Open Questions
- [x] Can we limit the scope of the resources made accessible to cert-manager and ExternalDNS to only the specific Route53 hosted zone that is provisioned by the XDelegatedHostedZoneAWS composition?
  - Answer: Yes. We will scope permissions to the specific delegated hosted
    zone ARN and remove wildcard hosted zone access from controller policies.

- [ ] What authentication and integrity mechanism should the trust anchor API
  enforce?
  - Candidates: mTLS between clusters, signed JWT with short TTL, and signed
    certificate payload with key rotation.

### Open Question Deep Dive: Trust Anchor API Authentication and Integrity

Options considered:

1. mTLS only
   - Pros: strong transport security and workload identity-based authentication.
   - Cons: does not provide standalone payload provenance if responses are
     forwarded through intermediaries.

2. JWT only
   - Pros: simple to integrate with API gateway authn/authz.
   - Cons: introduces token issuance and rotation dependencies; weaker
     cryptographic binding to the transport workload identity unless carefully
     designed.

3. mTLS + signed response payload (selected)
   - Pros: defense in depth with workload identity authentication and explicit
     response integrity verification.
   - Pros: allows strict replay protection and auditable verification failures.
   - Cons: additional signing key lifecycle management.

4. Network allowlist only
   - Pros: simple operationally.
   - Cons: insufficient for trust-anchor distribution and not acceptable as the
     primary control.

Selected approach (v1):
- Require SPIFFE-based mTLS between caller and trust-anchor API.
- Restrict caller identities to an allowlist of SPIFFE IDs for the crossplane
  controller workload.
- Return trust anchor payload with signed metadata:
  - `certificatePem`
  - `serialNumber`
  - `notBefore`
  - `notAfter`
  - `sha256Fingerprint`
  - `issuedAt`
  - `expiresAt`
  - `version`
  - `nonce`
- Include signature headers:
  - `signatureKeyId`
  - `signatureAlgorithm`
  - `payloadSignature`
- Client verification order:
  1. verify mTLS server identity and trust chain
  2. verify payload signature against trusted key set
  3. enforce freshness (`issuedAt`/`expiresAt`) with bounded clock skew
  4. reject replayed `nonce`/`version` responses

Acceptance criteria for closing this open question:
- [ ] Trust-anchor API rejects unauthenticated or unauthorized callers.
- [ ] Crossplane-side controller verifies signature and freshness before using
  returned certificate data.
- [ ] Replay and tampered response tests fail closed.
- [ ] Signing key rotation procedure is documented and tested.

Remaining sub-decisions:
- [ ] Choose signing key backend (KMS asymmetric key vs in-cluster key pair).
- [ ] Define allowed caller SPIFFE IDs and ownership model.
- [ ] Define freshness and cache policy (max skew and TTL).
- [ ] Define key rotation overlap window and rollback behavior.

## Implementation Plan

### Phase 0: Documentation and design baseline
- [ ] Replace wildcard IAM policy examples with zone-scoped examples in this
  ADR and related implementation docs.
- [ ] Add a sequence diagram for certificate issuance, trust anchor retrieval,
  Roles Anywhere credential exchange, and Route53 API access.
- [ ] Define explicit rollback strategy for each phase.

### Phase 1: Certificate duration decision
- [ ] Evaluate 90-day vs 1-year vs 5-year trust anchor duration for
  `csi-driver-spiffe-ca`.
- [ ] Document decision criteria:
  - compromise window
  - operational overhead of rotations
  - blast radius of failed rollout
- [ ] Publish runbooks for:
  - scheduled rotation
  - emergency key compromise rollover
- [ ] Update certificate duration only after runbooks are approved.

Acceptance criteria:
- [ ] The chosen duration and rationale are documented.
- [ ] A tested rotation procedure exists and is linked from this ADR.

### Phase 2: Trust anchor retrieval service
- [ ] Build a service that exposes the trust anchor certificate and metadata
  (`serial`, `notBefore`, `notAfter`, `sha256`).
- [ ] Add authentication and authorization for cross-cluster callers.
- [ ] Add integrity controls (payload signing and key rotation process).
- [ ] Emit audit logs for all retrieval requests and validation failures.

Acceptance criteria:
- [ ] Crossplane cluster can retrieve and validate the trust anchor without
  manual steps.
- [ ] Unauthorized and tampered responses are rejected in tests.

### Phase 3: Crossplane composition for IAM Roles Anywhere resources
- [ ] Create a new XRD for workload IAM Roles Anywhere access.
- [ ] Implement composition resources:
  - [ ] Role
  - [ ] Policy
  - [ ] RolePolicyAttachment
  - [ ] Profile
  - [ ] TrustAnchor
- [ ] Inputs include:
  - SPIFFE URI
  - hosted zone ID
  - AWS account ID
  - region
  - trust anchor certificate reference
- [ ] Outputs include:
  - role ARN
  - profile ARN
  - trust anchor ARN

Acceptance criteria:
- [ ] Composition reconciles end-to-end in a test environment.
- [ ] Produced IAM policy is scoped to one hosted zone ARN.

### Phase 4: Workload integration (ExternalDNS and CertManager)
- [ ] Configure ExternalDNS to target known hosted zone identifiers and avoid
  account-wide zone discovery in steady state.
- [ ] Configure CertManager Route53 solver to use hosted zone identifiers for
  delegated zones.
- [ ] Inject IAM Roles Anywhere credential helper sidecar and SPIFFE CSI volume
  using chart-native values when available.

Acceptance criteria:
- [ ] ExternalDNS can create/update/delete records only in delegated zones.
- [ ] CertManager DNS01 challenges succeed only in delegated zones.

### Phase 5: Validation and release
- [ ] Add conformance tests for:
  - positive flow in delegated zone
  - negative flow in non-delegated zone
  - trust anchor retrieval failure modes
- [ ] Run render and policy lint checks before merge.
- [ ] Promote through environments with canary rollout and documented rollback.

Acceptance criteria:
- [ ] Security and functionality tests pass in CI.
- [ ] Operational handoff documentation is complete.

## References
- [AWS IAM Access for non-AWS workloads](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_common-scenarios_non-aws.html)
- [AWS IAM Roles Anywhere Introduction](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html)
- [AWS IAM Roles Anywhere Getting Started](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/getting-started.html)
- [AWS IAM Roles Anywhere Workload Identities](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/workload-identities.html)
- [AWS IAM Roles Anywhere - Introduction & Demo | Amazon Web Services](https://www.youtube.com/watch?v=DOH37VVadlc)
- [cert-manager can do SPIFFE? - Civo Navigate NA 2023](https://www.youtube.com/watch?v=3CflMN1sIoM)
- [Securing Edge Workloads With Cert-Manager And SPIFFE - Sitaram IYER & Riaz Mohamed, Jetstack Ltd](https://www.youtube.com/watch?v=Ft8pvHg8iI4)
- [Solving the Bottom Turtle](https://spiffe.io/pdf/Solving-the-bottom-turtle-SPIFFE-SPIRE-Book.pdf)

## Application Components
- [approver-policy](https://cert-manager.io/docs/policy/approval/approver-policy/) controller to implement approval policies for certificante requests in the cluster.
- [trust-manager](https://cert-manager.io/docs/trust/trust-manager/#overview) controller to implement trust bundles for certificate authorities in the cluster.
- [cert-manager-spiffe](https://cert-manager.io/docs/usage/csi-driver-spiffe/installation/) controller to implement the SPIFFE CSI driver for cert-manager, which can be used to issue SPIFFE X.509 SVID certificates to workloads in the cluster.

## Related implementations

- [provider-aws-route53](../../applications/crossplane-providers/provider-aws-route53)
- [provider-aws-iam](../../applications/crossplane-providers/provider-aws-iam)