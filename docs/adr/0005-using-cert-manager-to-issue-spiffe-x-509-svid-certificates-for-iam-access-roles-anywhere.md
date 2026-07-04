# 5. Using cert-manager to issue SPIFFE X.509 SVID Certificates for IAM Access Roles Anywhere

Date: 2026-04-12

## Status

Accepted

## Context

I want to manage access to AWS resources from Kubernetes workloads using IAM Access Roles Anywhere. This requires issuing SPIFFE X.509 SVID certificates to the workloads, which can be issued using cert-manager. 

## References
- [AWS IAM Access for non-AWS workloads](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_common-scenarios_non-aws.html)
- [AWS IAM Roles Anywhere Introduction](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html)
- [AWS IAM Roles Anywhere Getting Started](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/getting-started.html)
- [AWS IAM Roles Anywhere Workload Identities](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/workload-identities.html)
- [AWS IAM Roles Anywhere - Introduction & Demo | Amazon Web Services](https://www.youtube.com/watch?v=DOH37VVadlc)
- [cert-manager can do SPIFFE? - Civo Navigate NA 2023](https://www.youtube.com/watch?v=3CflMN1sIoM)
- [Securing Edge Workloads With Cert-Manager And SPIFFE - Sitaram IYER & Riaz Mohamed, Jetstack Ltd](https://www.youtube.com/watch?v=Ft8pvHg8iI4)
- [Solving the Bottom Turtle](https://spiffe.io/pdf/Solving-the-bottom-turtle-SPIFFE-SPIRE-Book.pdf)

## Decision

- Modify the cert-manager deployment to disable the internal auto-approver.
- Install the [approver-policy](https://cert-manager.io/docs/policy/approval/approver-policy/) controller to implement approval policies for certificante requests in the cluster.
- Install the [trust-manager](https://cert-manager.io/docs/trust/trust-manager/#overview) controller to implement trust bundles for certificate authorities in the cluster.
- Install the [cert-manager-spiffe](https://cert-manager.io/docs/usage/csi-driver-spiffe/installation/) controller to implement the SPIFFE CSI driver for cert-manager, which can be used to issue SPIFFE X.509 SVID certificates to workloads in the cluster.
- Configure IAM Access Roles Anywhere to trust the certificates issued by cert-manager, and to map the SPIFFE IDs in the certificates to IAM roles that can be assumed by the workloads in the cluster.

## Consequences

- An approval policy will need to be implemented to approve certificate requests for external issuers to maintain previously expected behaviors of the cert-manager deployment.

## Certificate Key Usage Requirements for `csi-driver-spiffe-ca`

The `csi-driver-spiffe-ca` certificate issued by cert-manager must carry a
precisely specified set of key usages. The correct set depends on how the cert
is consumed downstream.

### Key usages

| Usage | Type | Required when |
|---|---|---|
| `digital signature` | Key Usage | Always |
| `cert sign` | Key Usage | Always — cert is a CA |
| `crl sign` | Key Usage | step-ca CRL is enabled. Go's `crypto/x509` checks the `crlSign` key usage bit before generating a CRL and returns an error if it is absent. |
| `ocsp signing` | Extended Key Usage | An OCSP responder (e.g., step-ca OCSP) needs to sign responses using this cert. |
| `server auth` | Extended Key Usage | **Required whenever any `ExtendedKeyUsage` is explicitly set.** Go's `crypto/tls` package enforces that if an `ExtendedKeyUsage` extension is present in the certificate, it must contain `ExtKeyUsageServerAuth` for the certificate to be accepted as a TLS server certificate. Omitting `server auth` while including any other extended key usage (e.g., `ocsp signing`) causes TLS clients to reject the connection with `x509: certificate specifies an incompatible key usage`. |

The minimum set for a cert used as both a CA and a TLS server cert with CRL
and OCSP capability enabled is:

```yaml
# applications/cert-manager-spiffe-issuer/base/resources/csi-driver-spiffe-ca.certificate.yaml
spec:
  isCA: true
  usages:
    - digital signature
    - cert sign
    - crl sign
    - ocsp signing
    - server auth
```

### approver-policy alignment

When cert-manager's `approver-policy` controller is deployed (as it is in this
platform — see the Decision above), `CertificateRequestPolicy.spec.allowed.usages`
must explicitly enumerate **every** usage that any `Certificate` in scope will
request via `spec.usages`. An empty or `nil` `allowed.usages` causes
approver-policy to deny all explicitly-requested usages, including standard
defaults. Every usage listed in `Certificate.spec.usages` must also appear in
the matching policy's `allowed.usages`:

```yaml
# applications/cert-manager-spiffe-issuer/base/resources/csi-driver-spiffe-ca.certificaterequestpolicy.yaml
spec:
  allowed:
    usages:
      - digital signature
      - cert sign
      - crl sign
      - ocsp signing
      - server auth
```

### cert-manager backoff after a failed CertificateRequest

When a `CertificateRequest` is denied (e.g., because the policy did not allow
a requested usage), cert-manager enters a one-hour retry backoff. The
`reissue-requested: "true"` annotation on the `Certificate` does **not** bypass
this backoff — the backoff check in cert-manager's trigger controller runs
before the annotation is evaluated. To force an immediate re-issue after fixing
the policy, clear `status.lastFailureTime` on the certificate:

```bash
kubectl patch certificate -n cert-manager csi-driver-spiffe-ca \
  --subresource=status --type=merge \
  -p '{"status":{"lastFailureTime":null}}'
```


## Validating step-ca connectivity

After deploying step-ca, verify the health endpoint and confirm the root CA certificate is served correctly.

### Health check

The step-ca health endpoint is reachable at `https://ca.crossplane.rye.ninja/health`. Because step-ca serves a self-signed certificate, pass `-k` to skip CA verification:

```bash
curl -sk https://ca.crossplane.rye.ninja/health
# expected: {"status":"ok"}
```

### Root CA fingerprint retrieval

The root CA fingerprint is derived from the `csi-driver-spiffe-ca` secret in the `step-ca` namespace:

```bash
export KUBECONFIG=~/.kube/spot/ryezone-labs/crossplane-controlplane-cluster.yaml

FINGERPRINT=$(kubectl get secret csi-driver-spiffe-ca -n step-ca \
  -o jsonpath='{.data.tls\.crt}' \
  | base64 -d \
  | openssl x509 -noout -fingerprint -sha256 \
  | sed 's/.*=//;s/://g' \
  | tr '[:upper:]' '[:lower:]')

echo "Fingerprint: $FINGERPRINT"
```

### Root CA endpoint validation

Use the fingerprint to retrieve the root CA certificate from the step-ca API:

```bash
curl -sk "https://ca.crossplane.rye.ninja/root/${FINGERPRINT}" | python3 -m json.tool
# expected: {"ca": "-----BEGIN CERTIFICATE-----\n..."}
```

A successful response confirms that step-ca is running, has loaded the correct root CA, and the `/root/<fingerprint>` API is reachable.

## Configuring AWS IAM Access Roles Anywhere to trust cert-manager issued SPIFFE certificates

Use the existing CloudFormation stack in [providers/aws/crossplane-iam-roles-anywhere.yaml](../../providers/aws/crossplane-iam-roles-anywhere.yaml) to bootstrap the IAM Roles Anywhere trust anchor, IAM role, and profile for cert-manager issued SPIFFE certificates.

The stack provisions the following resources together:

- `AWS::RolesAnywhere::TrustAnchor`
- `AWS::IAM::Role`
- `AWS::RolesAnywhere::Profile`

It also exports the outputs needed by downstream bootstrap and composition steps:

- `TrustAnchorArn`
- `TrustAnchorId`
- `RoleArn`
- `ProfileArn`

```bash
SPIFFE_CA_NAMESPACE=cert-manager
SPIFFE_CA_NAME=csi-driver-spiffe-ca
SPIFFE_CA_SECRET_NAME=`kubectl get certificate -n ${SPIFFE_CA_NAMESPACE} ${SPIFFE_CA_NAME} -o jsonpath='{.spec.secretName}'`
SPIFFE_CA_CERT=$(kubectl get secret -n ${SPIFFE_CA_NAMESPACE} ${SPIFFE_CA_SECRET_NAME} -o jsonpath='{.data.ca\.crt}' | base64 --decode)

aws cloudformation deploy \
  --profile ops-opex-dns-automation \
  --stack-name crossplane-provider-dns-admin \
  --template-file providers/aws/crossplane-iam-roles-anywhere.yaml \
  --parameter-overrides \
    ParameterKey=RoleName,ParameterValue=crossplane-provider-dns-admin \
    ParameterKey=SpiffeUri,ParameterValue=spiffe://cluster.local/ns/crossplane-system/sa/aws-route53-dns-provider \
    ParameterKey=CaX509Cert,ParameterValue="${SPIFFE_CA_CERT}" \
  --capabilities CAPABILITY_NAMED_IAM

aws cloudformation describe-stacks \
  --profile ops-opex-dns-automation \
  --stack-name crossplane-provider-dns-admin \
  --query 'Stacks[0].Outputs[?starts_with(OutputKey, `TrustAnchor`) || OutputKey==`RoleArn` || OutputKey==`ProfileArn`]' \
  --output table
```