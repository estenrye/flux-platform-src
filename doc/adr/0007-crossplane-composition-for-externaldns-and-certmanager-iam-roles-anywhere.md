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

The change that we're proposing or have agreed to implement.

## Open Questions
- [ ] Can we limit the scope of the resources made accsssible to cert-manager and ExternalDNS to only the specific Route53 hosted zone that is provisioned by the XDelegatedHostedZoneAWS composition, rather than granting permissions to all hosted zones in the AWS account?  This would follow the principle of least privilege and enhance the security of our AWS environment by minimizing the permissions granted to cert-manager and ExternalDNS.

## Action Items
- [ ] Evaluate the pros/cons of increasing the `.spec.duration` field of the [csi-driver-spiffe-ca](../../applications/cert-manager-spiffe-issuer/base/resources/csi-driver-spiffe-ca.certificate.yaml) `Certificate` resource to 5 years to ensure that the trust anchor certificate has a long validity period, which is important for the stability of the IAM Roles Anywhere trust relationship and minimize the need for frequent certificate rotations.
- [ ] Build a service that can be used to retrieve the trunst anchor certificate from the cluster via a public API endpoint.  This will allow our crossplane cluster to have a controller that can retrieve the trust anchor certificate and use it to provision IAM Roles Anywhere trust relationships.
- [ ] Build a Crossplane Composition that provisions the necessary AWS resources for IAM Roles Anywhere, which may include the following:
  - [ ] Role
  - [ ] Policy
  - [ ] RolePolicyAttachment
  - [ ] Profile
  - [ ] TrustAnchor

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