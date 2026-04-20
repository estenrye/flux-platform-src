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


## Configuring AWS IAM Access Roles Anywhere to trust cert-manager issued SPIFFE certificates

- Create a trust anchor in IAM Access Roles Anywhere that corresponds to the CA certificate used by cert-manager to issue SPIFFE X.509 SVID certificates.

```bash
SPIFFE_CA_NAMESPACE=cert-manager
SPIFFE_CA_NAME=csi-driver-spiffe-ca
SPIFFE_CA_SECRET_NAME=`kubectl get certificate -n ${SPIFFE_CA_NAMESPACE} ${SPIFFE_CA_NAME} -o jsonpath='{.spec.secretName}'`
SPIFFE_CA_CERT=$(kubectl get secret -n ${SPIFFE_CA_NAMESPACE} ${SPIFFE_CA_SECRET_NAME} -o jsonpath='{.data.ca\.crt}' | base64 --decode)

aws cloudformation create-stack \
  --profile AdministratorAccess-IAMIC-832767337984 \
  --stack-name crossplane-provider-dns-admin \
  --template-body file://providers/aws/crossplane-iam-roles-anywhere.yaml \
  --parameters \
    ParameterKey=RoleName,ParameterValue=crossplane-provider-dns-admin \
    ParameterKey=SpiffeUri,ParameterValue=spiffe://cluster.local/ns/crossplane-system/sa/aws-route53-dns-provider \
    ParameterKey=CaX509Cert,ParameterValue="${SPIFFE_CA_CERT}" \
  --capabilities CAPABILITY_NAMED_IAM
```