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
  description = "Allow ExternalDNS to access Route53 hosted zones and manage DNS records"

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
          "arn:aws:route53:::hostedzone/*"
        ],
        "Condition": {
          "ForAllValues:StringLike": {
            "route53:ChangeResourceRecordSetsActions": ["CREATE", "UPSERT", "DELETE"],
            "route53:ChangeResourceRecordSetsRecordTypes": ["A", "AAAA", "CNAME", "TXT"]
          }
        }
      },
      {
        "Effect": "Allow",
        "Action": [
          "route53:ListHostedZones"
        ],
        "Resource": [
          "*"
        ]
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

2. One workload identity per role
   - ExternalDNS and CertManager will each have a dedicated IAM Role,
     Roles Anywhere Profile, and SPIFFE URI condition in the role trust policy.
   - Shared IAM principals between controllers are not allowed.

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