# 2. Bootstrapping a Flux-Enabled Kubernetes Cluster

Date: 2025-12-03

## Status

Accepted

## Installing Prerequisite CLI Tooling

The following CLI tools are required to interact with
Flux enabled Kubernetes clusters.

| Executable | What is used for |
| ----------- | -----------------|
| `age`       | age is used to create asymetric keypairs that allow us to encrypt secrets at rest in the repository and deliver them securely to the target cluster |
| `aws`       | The AWS CLI is used to interact with AWS services such as EKS and IAM to manage clusters and user permissions. |
| `awsv2`     | The AWS CLI v2 is used to interact with AWS services such as EKS and IAM to manage clusters and user permissions. |
| `chainsaw`  | Chainsaw is used to run platform validation tests against the Kubernetes API to ensure that the cluster is operating as expected after configuration changes are applied. |
| `flux`      | The Flux CLI is used to create Repository Secrets, GitRepository and Kustomization custom resources. |
| `gh`        | The GitHub CLI is used for adding/removing SSH Deploy Keys from the repository. |
| `jq`        | jq is used to interact with and modify JSON formatted files. |
| `kubectl`   | kubectl is used to install the Flux Operator and perform the initial deployment of the SOPS private key secret, Repository Secret, GitRepository and Kustomization custom resources. |
| `kustomize` | Kustomize will be used throughout the cluster lifecycle to patch, build and test application manifests being delivered to the cluster. |
| `saml2aws`  | saml2aws is used to authenticate against SAML2 identity providers to retrieve temporary AWS credentials for interacting with EKS clusters. |
| `sops`      | SOPS will be used in conjunction with GnuPG to encrypt secrets at rest prior to committing them to the repository. |
| `spotctl`   | spotctl is used to manage Rackspace Spot clusters. |
| `yq`        | yq is used to interact with and modify YAML formatted files. |

To ensure a consistent development environment across machines, a number of scripts
are provided to install the required CLI tools at the required versions.  These
scripts have been integrated into a python virtual environment that is launched
and installed automatically when you open this repository in VSCode.

If you are not using VSCode, you can manually install the required CLI tools
using the provided installation scripts located in the `.bin` directory.  The
following command will install all required CLI tools, activate the python
virtual environment, and install any required python packages using a bash
terminal.

```bash
bash --init-file ./.bin/.bashrc
```

## References

- [FluxCD Docs: Flux Installation](https://fluxcd.io/flux/installation/#prerequisites)
- [FluxCD Docs: Manage Kubernetes Secrets with SOPS](https://fluxcd.io/flux/guides/mozilla-sops/)
- [FluxCD Docs: Flux CLI: Create Repository Secret](https://fluxcd.io/flux/cmd/flux_create_secret_git/)
- [FluxCD Docs: Flux CLI: Create GitRepository](https://fluxcd.io/flux/cmd/flux_create_source_git/)
- [FluxCD Docs: Flux CLI: Create Kustomization](https://fluxcd.io/flux/cmd/flux_create_kustomization/)
- [Github Docs: gh CLI: Authenticating the CLI](https://cli.github.com/manual/gh_auth_login)
- [Github Docs: gh CLI: Adding Repository Deploy Keys](https://cli.github.com/manual/gh_repo_deploy-key_add)
- [Github Docs: gh CLI: Deleting Repository Deploy Keys](https://cli.github.com/manual/gh_repo_deploy-key_delete)
- [Github Docs: gh CLI: Listing Repository Deploy Keys](https://cli.github.com/manual/gh_repo_deploy-key_list)
- [Github: FiloSottile/age](https://github.com/FiloSottile/age)
- [Github: kyverno/chainsaw](https://github.com/kyverno/chainsaw)
- [Github: fluxcd/flux2](https://github.com/fluxcd/flux2)
- [Github: getsops/sops](https://github.com/getsops/sops)
- [Github: cli/cli](https://github.com/cli/cli)
- [Github: kubernetes/kubectl](https://github.com/kubernetes/kubectl)
- [Github: kubernetes-sigs/kustomize](https://github.com/kubernetes-sigs/kustomize)
- [Github: stakater/Reloader](https://github.com/stakater/Reloader/tree/master)