# M2 Migration Inventory: crossplane (Rackspace Spot)

Generated: 2026-07-11T07:59:02Z by `.bin/generate-migration-inventory.sh crossplane`

Disposition legend: `move-state` (import with same external-name), `recreate` (fresh install via Flux), `retire` (do not migrate), `n/a`, or blank (decide during M2 planning).

## Crossplane managed resources

Migration rule: set deletionPolicy=Orphan, pause, export, import by external-name, verify observe-not-recreate.

| Kind | Namespace/Name | External name | ProviderConfig | DeletionPolicy | Ready | Disposition |
|---|---|---|---|---|---|---|
| DeployKey | flux-system/crossplane-flux-ssh-deploykey | flux-platform-rendered:152600034 | default | Delete | True |  |
| Policy | crossplane-controlplane-cluster/delegated-zone-crossplane-rye-ninja | delegated-zone-crossplane-rye-ninja | iam-admin | Delete | True |  |
| Profile | crossplane-controlplane-cluster/delegated-zone-crossplane-rye-ninja | 296475b1-698c-44c9-9af6-35ad2ba0c6a5 | rolesanywhere-admin | Delete | True |  |
| Record | crossplane-controlplane-cluster/ns0-crossplane-rye-ninja | 78a6381098cdc8b26a5bf107a930cb18 | cloudflare-provider-config | Delete | True |  |
| Record | crossplane-controlplane-cluster/ns1-crossplane-rye-ninja | daebfabed8388ac2bd8365b33161ff7f | cloudflare-provider-config | Delete | True |  |
| Record | crossplane-controlplane-cluster/ns2-crossplane-rye-ninja | a8681532ea869cd8684931eabc714b3b | cloudflare-provider-config | Delete | True |  |
| Record | crossplane-controlplane-cluster/ns3-crossplane-rye-ninja | 8b4ce8af99fffdd09c3998a518bb8dc1 | cloudflare-provider-config | Delete | True |  |
| Role | crossplane-controlplane-cluster/delegated-zone-crossplane-rye-ninja | delegated-zone-crossplane-rye-ninja | iam-admin | Delete | True |  |
| RolePolicyAttachment | crossplane-controlplane-cluster/delegated-zone-crossplane-rye-ninja | delegated-zone-crossplane-rye-ninja/arn:aws:iam::832767337984:policy/delegated-zone-crossplane-rye-ninja | iam-admin | Delete | True |  |
| Zone | crossplane-controlplane-cluster/crossplane-rye-ninja | Z087069529GAZBM0GNQPI | dns-admin | Delete | True |  |

## Claims and composite resources

| Kind | Namespace/Name | Composition | Ready | Disposition |
|---|---|---|---|---|
| XDelegatedHostedZoneAWS | crossplane-controlplane-cluster/crossplane-rye-ninja | delegated-hosted-zone-aws | True |  |

## XRDs and Compositions (installed via Flux; recreate on target)

```
NAME                                             ESTABLISHED
xdelegatedhostedzoneaws.dns.platform.rye.ninja   True
NAME                        XR-KIND
delegated-hosted-zone-aws   XDelegatedHostedZoneAWS
```

## Providers, functions, runtime configs (recreate via Flux)

```
crossplane-contrib-provider-upjet-github   xpkg.upbound.io/crossplane-contrib/provider-upjet-github:v0.19.0
provider-kubernetes                        xpkg.crossplane.io/crossplane-contrib/provider-kubernetes:v1.0.0
upbound-provider-aws-iam                   xpkg.upbound.io/upbound/provider-aws-iam:v2.5.2
upbound-provider-aws-rolesanywhere         xpkg.upbound.io/upbound/provider-aws-rolesanywhere:v2.5.2
upbound-provider-aws-route53               xpkg.upbound.io/upbound/provider-aws-route53:v2.5.2
upbound-provider-family-aws                xpkg.upbound.io/upbound/provider-family-aws:v2.5.2
wildbitca-provider-cloudflare-dns          xpkg.upbound.io/wildbitca/provider-cloudflare-dns:v0.2.6
wildbitca-provider-cloudflare-zone         xpkg.upbound.io/wildbitca/provider-cloudflare-zone:v0.2.6
wildbitca-provider-family-cloudflare       xpkg.upbound.io/wildbitca/provider-family-cloudflare:v0.2.6
function-auto-ready            xpkg.crossplane.io/crossplane-contrib/function-auto-ready:v0.6.5
function-environment-configs   xpkg.crossplane.io/crossplane-contrib/function-environment-configs:v0.7.1
function-go-templating         xpkg.upbound.io/crossplane-contrib/function-go-templating:v0.12.1
deploymentruntimeconfig.pkg.crossplane.io/aws-iam-admin-provider
deploymentruntimeconfig.pkg.crossplane.io/aws-rolesanywhere-admin-provider
deploymentruntimeconfig.pkg.crossplane.io/aws-route53-dns-provider
deploymentruntimeconfig.pkg.crossplane.io/default
deploymentruntimeconfig.pkg.crossplane.io/provider-kubernetes
environmentconfig.apiextensions.crossplane.io/platform-cloudflare
environmentconfig.apiextensions.crossplane.io/platform-iam-rolesanywhere
providerconfig.kubernetes.crossplane.io/kubernetes-provider
clusterproviderconfig.upjet-cloudflare.m.upbound.io/cloudflare-provider-config
clusterproviderconfig.upjet-cloudflare.m.upbound.io/default
```

## CNPG databases (move-state via barman backup/restore)

| Cluster | Namespace | Instances | Ready | Storage | Backup config | Disposition |
|---|---|---|---|---|---|---|
| step-ca-db | step-ca | 3 | 1 | 10Gi | NONE | move-state |

## Flux topology (recreate: new cluster entry + rendered repo)

```
flux-system   flux-platform                                  45d   True   Applied revision: main@sha1:4f983fee12a75b146cefebc3da32aa8eb0a7199d
flux-system   flux-platform-external-dns-aws-rolesanywhere   39d   True   Applied revision: main@sha1:4f983fee12a75b146cefebc3da32aa8eb0a7199d
flux-system   flux-platform-rendered   ssh://git@github.com/estenrye/flux-platform-rendered.git   main
```

## SOPS-encrypted secrets in repo

```
.bin/bootstrap-cluster-sops-key.sh
.bin/bootstrap-sops-secret.sh
.bin/install-sops.sh
.bin/rotate-cluster-sops-key.sh
.bin/test/test-rotate-cluster-sops-key.sh
clusters/crossplane/.sops.age-key
clusters/crossplane/.sops.yaml
```

## In-cluster Secrets not owned by a controller (manual decisions)

Excludes helm releases, SA tokens, and secrets owned by cert-manager/ESO/Flux/CNPG/Crossplane.

```
cert-manager/cert-manager-webhook-ca (Opaque)
cert-manager/csi-driver-spiffe-ca (kubernetes.io/tls)
cert-manager/trust-manager-tls (kubernetes.io/tls)
crossplane-system/aws-account-creds (Opaque)
crossplane-system/crossplane-root-ca (Opaque)
crossplane-system/crossplane-tls-client (Opaque)
crossplane-system/crossplane-tls-server (Opaque)
envoy-gateway-system/envoy (kubernetes.io/tls)
envoy-gateway-system/envoy-gateway (kubernetes.io/tls)
envoy-gateway-system/envoy-oidc-hmac (Opaque)
envoy-gateway-system/envoy-rate-limit (kubernetes.io/tls)
external-secrets-operator/onepassword-sdk-token (Opaque)
flux-system/sops-age (Opaque)
step-ca/step-certificates-secrets (smallstep.com/private-keys)
```

## External Secrets

```
1password-sdk   46d   Valid   ReadWrite   True
step-ca   cert-manager-secrets   28d   Valid   ReadWrite   True
crossplane-system   cloudflare-creds       ClusterSecretStore   1password-sdk          1h0m0s   SecretSynced   True   31d
crossplane-system   github-token           ClusterSecretStore   1password-sdk          1h0m0s   SecretSynced   True   31d
flux-system         flux-ssh-key-secret                                                1h0m0s   SecretSynced   True   45d
step-ca             csi-driver-spiffe-ca   SecretStore          cert-manager-secrets   1h       SecretSynced   True   41m
```

## DNS records referencing this cluster

From in-cluster managed resources (Route53/Cloudflare) plus known platform names.

```
Record: 78a6381098cdc8b26a5bf107a930cb18 -> crossplane NS ns-1025.awsdns-00.org
Record: daebfabed8388ac2bd8365b33161ff7f -> crossplane NS ns-1705.awsdns-21.co.uk
Record: a8681532ea869cd8684931eabc714b3b -> crossplane NS ns-55.awsdns-06.com
Record: 8b4ce8af99fffdd09c3998a518bb8dc1 -> crossplane NS ns-672.awsdns-20.net
Zone: Z087069529GAZBM0GNQPI -> crossplane.rye.ninja  
```

Known platform names (verify at cutover): `ca.crossplane.rye.ninja` -> gateway LB 174.143.59.222

## PKI identity (MUST NOT change in M2)

- Root fingerprint (sha256): `454b03bf485f2a70f84b6c290e3ff3eaaef30ef192822c5f69d8c593f7635add` - disposition: **move-state** (root key material from SOPS)
- Root subject: `subject=CN=csi-driver-spiffe-ca`
- Root expiry: `notAfter=Oct  2 03:17:14 2026 GMT`
- Live trust domain: `cluster.local` (ADR-16 drift finding; new cluster uses controlplane.rye.ninja)
- ClusterIssuers: clusterissuer.cert-manager.io/csi-driver-spiffe-ca clusterissuer.cert-manager.io/selfsigned 

## Resource headroom snapshot

```
NAME                              CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%   
prod-instance-17757113359720464   49m          3%     2106Mi          75%       
prod-instance-17784426998252084   52m          3%     1793Mi          64%       
prod-instance-17784439284322117   72m          4%     2192Mi          78%       
prod-instance-17832871248992596   85m          2%     3613Mi          53%       
```

Top pod consumers:
```
NAMESPACE                   NAME                                                              CPU(cores)   MEMORY(bytes)   
crossplane-system           upbound-provider-aws-rolesanywhere-9869d014d3e5-5fd9dbc5bc5brtr   1m           443Mi           
crossplane-system           upbound-provider-aws-iam-2d88652ceaa3-d4cfc4b97-mq9mc             4m           331Mi           
crossplane-system           upbound-provider-aws-route53-d4cc2130f076-6cd64bcf9d-kgdzx        2m           295Mi           
crossplane-system           upbound-provider-family-aws-d6504ac17c4c-7b66b8964f-qv4r5         7m           259Mi           
crossplane-system           wildbitca-provider-cloudflare-dns-2dc377c3b104-5df59d98b9-wmmgv   57m          191Mi           
crossplane-system           crossplane-65dbdfd97c-j29jw                                       3m           165Mi           
crossplane-system           crossplane-contrib-provider-upjet-github-67cb3824c483-69f72mw4z   5m           163Mi           
calico-system               calico-node-s66xf                                                 9m           151Mi           
calico-system               calico-node-hnbhm                                                 20m          140Mi           
calico-system               calico-node-6xk8k                                                 11m          140Mi           
crossplane-system           wildbitca-provider-cloudflare-zone-9f0bcaa63c35-799ff9594cbljdw   2m           137Mi           
calico-system               calico-node-zjvvk                                                 11m          133Mi           
crossplane-system           wildbitca-provider-family-cloudflare-aa314c22296f-d6d8588bsmxqv   1m           116Mi           
cert-manager                cert-manager-cainjector-cdb87bf6f-tfwsw                           1m           104Mi           
(metrics unavailable)
```

## Workstation and CI dependencies

- Kubeconfig: `~/.kube/spot/ryezone-labs/crossplane-controlplane-cluster.yaml` (from catalog annotation)
- Rendered repo: `estenrye/flux-platform-rendered`
- Source repo filter: `estenrye/flux-platform-src`

## Pre-filled dispositions (policy, from the plan)

- step-ca root key material: **move-state** (fleet trust anchor)
- `global-network-policy-default-deny/rackspace-spot` overlay and all `rackspace-spot` provider variants: **retire**
- Rackspace Spot LB / gateway addresses: **retire** (replaced by UniFi BGP VIPs)
