# HA step-ca + CNPG Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy the CNPG operator, Envoy Gateway, a HA Postgres cluster, and a HA step-ca instance on the crossplane cluster, all as Flux applications following the existing `applications/<name>/base/` pattern.

**Architecture:** Four new Flux applications (`cnpg`, `envoy-gateway`, `step-ca-db`, `step-ca`) are added to `clusters/crossplane/kustomization.yaml` in dependency order. step-ca uses Postgres (via CNPG) as its storage backend and mounts the `csi-driver-spiffe-ca` cert+key (sourced from the `cert-manager` namespace via ESO's Kubernetes provider) directly into the pod. Envoy Gateway exposes step-ca's CA API via TLS passthrough (port 443) and its CRL endpoint over HTTP (port 80).

**Tech Stack:** CloudNativePG 0.28.3 (appVersion 1.29.1), Envoy Gateway 1.8.1, step-certificates Helm chart 1.30.1 (appVersion 0.30.2), External Secrets Operator (existing), Kustomize + Helm, Gateway API (existing CRDs), Flux GitOps.

---

## File Map

```
applications/cnpg/base/
  kustomization.yaml
  values.yaml
  catalog.yaml
  resources/namespace.yaml
  patches/deployment.yaml

applications/envoy-gateway/base/
  kustomization.yaml
  values.yaml
  catalog.yaml
  resources/namespace.yaml
  resources/custom-proxy-config.envoyproxy.yaml
  resources/merged-eg.gatewayclass.yaml
  patches/deployment.yaml

applications/step-ca-db/base/
  kustomization.yaml
  catalog.yaml
  resources/namespace.yaml
  resources/network-policy.yaml
  resources/step-ca-db.cluster.yaml

applications/step-ca/base/
  kustomization.yaml
  values.yaml
  catalog.yaml
  resources/network-policy.yaml
  resources/eso.service-account.yaml
  resources/eso.cert-manager-role.yaml
  resources/eso.cert-manager-rolebinding.yaml
  resources/eso.secret-store.yaml
  resources/eso.external-secret.yaml
  resources/gateway.yaml
  resources/tls-route.yaml
  resources/http-route.yaml
  patches/deployment.yaml

clusters/crossplane/kustomization.yaml              (modify)
clusters/crossplane/patches/step-ca.gateway.yaml   (create)
```

---

## Task 1: `cnpg` application

**Files:**
- Create: `applications/cnpg/base/resources/namespace.yaml`
- Create: `applications/cnpg/base/patches/deployment.yaml`
- Create: `applications/cnpg/base/values.yaml`
- Create: `applications/cnpg/base/catalog.yaml`
- Create: `applications/cnpg/base/kustomization.yaml`

- [ ] **Step 1.1: Create the namespace resource**

```bash
mkdir -p applications/cnpg/base/resources applications/cnpg/base/patches
```

Create `applications/cnpg/base/resources/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cnpg-system
```

- [ ] **Step 1.2: Create the deployment hardening patch**

Create `applications/cnpg/base/patches/deployment.yaml`:
```yaml
- op: add
  path: /spec/template/spec/restartPolicy
  value: Always
- op: add
  path: /metadata/annotations/checkov.io~1skip1
  value: "CKV_K8S_38=CNPG controller requires the service account token to manage PostgreSQL cluster resources."
```

- [ ] **Step 1.3: Create the Helm values file**

Create `applications/cnpg/base/values.yaml`:
```yaml
{}
```

- [ ] **Step 1.4: Create the Backstage catalog entry**

Create `applications/cnpg/base/catalog.yaml`:
```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: cnpg
  description: |-
    CloudNativePG operator and CRDs for managing
    highly available PostgreSQL clusters in Kubernetes.
  tags:
    - database
    - postgresql
    - operators
    - crds
    - platform
    - infrastructure
spec:
  type: service
  lifecycle: production
  owner: platform-engineering
```

- [ ] **Step 1.5: Create the kustomization**

Create `applications/cnpg/base/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cnpg-system

resources:
  - resources/namespace.yaml

helmCharts:
  - name: cloudnative-pg
    repo: oci://ghcr.io/cloudnative-pg/charts
    version: 0.28.3
    releaseName: cnpg
    namespace: cnpg-system
    includeCRDs: true
    valuesFile: values.yaml

patches:
  - target:
      kind: Deployment
    path: patches/deployment.yaml

images:
  - name: ghcr.io/cloudnative-pg/cloudnative-pg
    newTag: "1.29.1"
    digest: sha256:0dfff19ba7b52ca25851a1010028b6940fff2e233290465af1cfb08a5f3f4661
```

- [ ] **Step 1.6: Validate the application renders**

```bash
cd applications/cnpg/base && kustomize build --enable-helm .
```

Expected: YAML output including a Deployment, ClusterRole, and CRD resources — no errors.

- [ ] **Step 1.7: Commit**

```bash
git add applications/cnpg/
git commit -m "feat: add cnpg operator application"
```

---

## Task 2: `envoy-gateway` application

**Files:**
- Create: `applications/envoy-gateway/base/resources/namespace.yaml`
- Create: `applications/envoy-gateway/base/resources/custom-proxy-config.envoyproxy.yaml`
- Create: `applications/envoy-gateway/base/resources/merged-eg.gatewayclass.yaml`
- Create: `applications/envoy-gateway/base/patches/deployment.yaml`
- Create: `applications/envoy-gateway/base/values.yaml`
- Create: `applications/envoy-gateway/base/catalog.yaml`
- Create: `applications/envoy-gateway/base/kustomization.yaml`

- [ ] **Step 2.1: Create directory structure**

```bash
mkdir -p applications/envoy-gateway/base/resources applications/envoy-gateway/base/patches
```

- [ ] **Step 2.2: Create the namespace resource**

Create `applications/envoy-gateway/base/resources/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: envoy-gateway-system
```

- [ ] **Step 2.3: Create the EnvoyProxy CR**

Create `applications/envoy-gateway/base/resources/custom-proxy-config.envoyproxy.yaml`:
```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: custom-proxy-config
  namespace: envoy-gateway-system
spec:
  mergeGateways: true
```

- [ ] **Step 2.4: Create the GatewayClass**

Create `applications/envoy-gateway/base/resources/merged-eg.gatewayclass.yaml`:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: merged-eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: custom-proxy-config
    namespace: envoy-gateway-system
```

- [ ] **Step 2.5: Create the deployment hardening patch**

Create `applications/envoy-gateway/base/patches/deployment.yaml`:
```yaml
- op: add
  path: /spec/template/spec/restartPolicy
  value: Always
- op: add
  path: /metadata/annotations/checkov.io~1skip1
  value: "CKV_K8S_38=Envoy Gateway controller requires the service account token to manage Gateway API resources."
```

- [ ] **Step 2.6: Create the Helm values file**

Create `applications/envoy-gateway/base/values.yaml`:
```yaml
{}
```

- [ ] **Step 2.7: Create the Backstage catalog entry**

Create `applications/envoy-gateway/base/catalog.yaml`:
```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: envoy-gateway
  description: |-
    Envoy Gateway controller implementing the Kubernetes
    Gateway API using Envoy Proxy as the data plane.
  tags:
    - gateway
    - networking
    - operators
    - platform
    - infrastructure
spec:
  type: service
  lifecycle: production
  owner: platform-engineering
```

- [ ] **Step 2.8: Create the kustomization**

Create `applications/envoy-gateway/base/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: envoy-gateway-system

resources:
  - resources/namespace.yaml
  - resources/custom-proxy-config.envoyproxy.yaml
  - resources/merged-eg.gatewayclass.yaml

helmCharts:
  - name: gateway-helm
    repo: oci://docker.io/envoyproxy
    version: 1.8.1
    releaseName: envoy-gateway
    namespace: envoy-gateway-system
    includeCRDs: true
    valuesFile: values.yaml

patches:
  - target:
      kind: Deployment
    path: patches/deployment.yaml

images:
  - name: docker.io/envoyproxy/gateway
    newTag: "v1.8.1"
    digest: sha256:497df13b71f4e544c7e80414873041e291776c28cd788bcbee0d18421fa5db98
  - name: docker.io/envoyproxy/ratelimit
    newTag: "ff287602"
    digest: sha256:f9df277f4c61459f6b26e06e0eb1f511e4da3c67ce133a39bd97a12dc5885eea
```

- [ ] **Step 2.9: Validate the application renders**

```bash
cd applications/envoy-gateway/base && kustomize build --enable-helm .
```

Expected: YAML output including a Deployment, the `merged-eg` GatewayClass, and the `custom-proxy-config` EnvoyProxy — no errors.

- [ ] **Step 2.10: Commit**

```bash
git add applications/envoy-gateway/
git commit -m "feat: add envoy-gateway application with merged GatewayClass"
```

---

## Task 3: `step-ca-db` application

**Files:**
- Create: `applications/step-ca-db/base/resources/namespace.yaml`
- Create: `applications/step-ca-db/base/resources/network-policy.yaml`
- Create: `applications/step-ca-db/base/resources/step-ca-db.cluster.yaml`
- Create: `applications/step-ca-db/base/catalog.yaml`
- Create: `applications/step-ca-db/base/kustomization.yaml`

- [ ] **Step 3.1: Create directory structure**

```bash
mkdir -p applications/step-ca-db/base/resources
```

- [ ] **Step 3.2: Create the namespace resource**

Create `applications/step-ca-db/base/resources/namespace.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: step-ca
```

- [ ] **Step 3.3: Create the NetworkPolicy**

This restricts Postgres ingress to only step-ca application pods. CNPG pod labels use `cnpg.io/cluster: <cluster-name>`.

Create `applications/step-ca-db/base/resources/network-policy.yaml`:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: step-ca-db
  namespace: step-ca
spec:
  podSelector:
    matchLabels:
      cnpg.io/cluster: step-ca-db
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: step-certificates
      ports:
        - protocol: TCP
          port: 5432
```

- [ ] **Step 3.4: Create the CNPG Cluster resource**

Create `applications/step-ca-db/base/resources/step-ca-db.cluster.yaml`:
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: step-ca-db
  namespace: step-ca
spec:
  instances: 3

  postgresql:
    parameters:
      max_connections: "100"

  bootstrap:
    initdb:
      database: stepcas
      owner: stepcas

  storage:
    size: 1Gi

  primaryUpdateStrategy: unsupervised

  monitoring:
    enablePodMonitor: true
```

- [ ] **Step 3.5: Create the Backstage catalog entry**

Create `applications/step-ca-db/base/catalog.yaml`:
```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: step-ca-db
  description: |-
    Highly available PostgreSQL cluster for step-ca,
    managed by the CloudNativePG operator.
  tags:
    - database
    - postgresql
    - platform
    - infrastructure
spec:
  type: service
  lifecycle: production
  owner: platform-engineering
```

- [ ] **Step 3.6: Create the kustomization**

No global namespace field — the CNPG Cluster and NetworkPolicy both declare `namespace: step-ca` explicitly.

Create `applications/step-ca-db/base/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - resources/namespace.yaml
  - resources/network-policy.yaml
  - resources/step-ca-db.cluster.yaml
```

- [ ] **Step 3.7: Validate the application renders**

```bash
cd applications/step-ca-db/base && kustomize build .
```

Expected: YAML output containing the Namespace, NetworkPolicy, and CNPG Cluster — no errors.

- [ ] **Step 3.8: Commit**

```bash
git add applications/step-ca-db/
git commit -m "feat: add step-ca-db CNPG cluster application"
```

---

## Task 4: `step-ca` — ESO resources for root CA key material

These resources enable ESO to read the `csi-driver-spiffe-ca` TLS Secret from the `cert-manager` namespace and make it available in `step-ca`.

**Files:**
- Create: `applications/step-ca/base/resources/eso.service-account.yaml`
- Create: `applications/step-ca/base/resources/eso.cert-manager-role.yaml`
- Create: `applications/step-ca/base/resources/eso.cert-manager-rolebinding.yaml`
- Create: `applications/step-ca/base/resources/eso.secret-store.yaml`
- Create: `applications/step-ca/base/resources/eso.external-secret.yaml`

- [ ] **Step 4.1: Create directory structure**

```bash
mkdir -p applications/step-ca/base/resources applications/step-ca/base/patches
```

- [ ] **Step 4.2: Create the ServiceAccount**

Create `applications/step-ca/base/resources/eso.service-account.yaml`:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: step-ca-cert-reader
  namespace: step-ca
```

- [ ] **Step 4.3: Create the Role in cert-manager namespace**

Create `applications/step-ca/base/resources/eso.cert-manager-role.yaml`:
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: step-ca-cert-reader
  namespace: cert-manager
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
    resourceNames: ["csi-driver-spiffe-ca"]
```

- [ ] **Step 4.4: Create the RoleBinding in cert-manager namespace**

Create `applications/step-ca/base/resources/eso.cert-manager-rolebinding.yaml`:
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: step-ca-cert-reader
  namespace: cert-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: step-ca-cert-reader
subjects:
  - kind: ServiceAccount
    name: step-ca-cert-reader
    namespace: step-ca
```

- [ ] **Step 4.5: Create the ESO SecretStore**

The Kubernetes provider reads from the `cert-manager` namespace using the `step-ca-cert-reader` ServiceAccount token.

Create `applications/step-ca/base/resources/eso.secret-store.yaml`:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: cert-manager-secrets
  namespace: step-ca
spec:
  provider:
    kubernetes:
      remoteNamespace: cert-manager
      server:
        caProvider:
          type: ConfigMap
          name: kube-root-ca.crt
          key: ca.crt
      auth:
        serviceAccount:
          name: step-ca-cert-reader
          namespace: step-ca
```

- [ ] **Step 4.6: Create the ExternalSecret**

Mirrors `tls.crt` and `tls.key` from `csi-driver-spiffe-ca` (cert-manager namespace) into a Secret of the same name in the `step-ca` namespace. step-ca pods mount this Secret directly.

Create `applications/step-ca/base/resources/eso.external-secret.yaml`:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: csi-driver-spiffe-ca
  namespace: step-ca
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: cert-manager-secrets
    kind: SecretStore
  target:
    name: csi-driver-spiffe-ca
    creationPolicy: Owner
  data:
    - secretKey: tls.crt
      remoteRef:
        key: csi-driver-spiffe-ca
        property: tls.crt
    - secretKey: tls.key
      remoteRef:
        key: csi-driver-spiffe-ca
        property: tls.key
```

---

## Task 5: `step-ca` — Gateway resources

**Files:**
- Create: `applications/step-ca/base/resources/gateway.yaml`
- Create: `applications/step-ca/base/resources/tls-route.yaml`
- Create: `applications/step-ca/base/resources/http-route.yaml`

- [ ] **Step 5.1: Create the Gateway**

The `https-passthrough` listener forwards TLS to step-ca unmodified — step-ca manages its own TLS certificate. The `http-crl` listener serves the CRL over plain HTTP as required by RFC 5280.

The hostname is intentionally omitted here and added by the cluster-specific patch in Task 7.

Create `applications/step-ca/base/resources/gateway.yaml`:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: step-ca
  namespace: step-ca
spec:
  gatewayClassName: merged-eg
  listeners:
    - name: https-passthrough
      port: 443
      protocol: TLS
      tls:
        mode: Passthrough
      allowedRoutes:
        namespaces:
          from: Same
    - name: http-crl
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
```

- [ ] **Step 5.2: Create the TLSRoute**

Routes TLS passthrough traffic on port 443 to step-ca's secure server (port 9000). `step-certificates` is the Service name produced by the Helm chart when `releaseName: step-certificates`.

Create `applications/step-ca/base/resources/tls-route.yaml`:
```yaml
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: step-ca
  namespace: step-ca
spec:
  parentRefs:
    - name: step-ca
      namespace: step-ca
      sectionName: https-passthrough
  rules:
    - backendRefs:
        - name: step-certificates
          port: 9000
```

- [ ] **Step 5.3: Create the HTTPRoute for CRL**

Routes `/1.0/crl` traffic on port 80 to step-ca's insecure server (port 9001).

Create `applications/step-ca/base/resources/http-route.yaml`:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: step-ca-crl
  namespace: step-ca
spec:
  parentRefs:
    - name: step-ca
      namespace: step-ca
      sectionName: http-crl
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /1.0/crl
      backendRefs:
        - name: step-certificates
          port: 9001
```

---

## Task 6: `step-ca` — Helm chart, NetworkPolicy, kustomization

**Files:**
- Create: `applications/step-ca/base/resources/network-policy.yaml`
- Create: `applications/step-ca/base/patches/deployment.yaml`
- Create: `applications/step-ca/base/values.yaml`
- Create: `applications/step-ca/base/catalog.yaml`
- Create: `applications/step-ca/base/kustomization.yaml`

- [ ] **Step 6.1: Create the NetworkPolicy**

Allows ingress from Envoy proxy pods on step-ca's two ports. Allows egress to the CNPG RW service, Kubernetes API (for ESO token exchange), and DNS.

Create `applications/step-ca/base/resources/network-policy.yaml`:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: step-ca
  namespace: step-ca
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: step-certificates
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: envoy-gateway-system
      ports:
        - protocol: TCP
          port: 9000
        - protocol: TCP
          port: 9001
  egress:
    - to:
        - podSelector:
            matchLabels:
              cnpg.io/cluster: step-ca-db
      ports:
        - protocol: TCP
          port: 5432
    - ports:
        - protocol: TCP
          port: 443
        - protocol: TCP
          port: 53
        - protocol: UDP
          port: 53
```

- [ ] **Step 6.2: Create the deployment hardening patch**

Adds the standard security context annotation and the Reloader annotation so step-ca restarts when ESO updates the `csi-driver-spiffe-ca` Secret after a root CA rotation.

Create `applications/step-ca/base/patches/deployment.yaml`:
```yaml
- op: add
  path: /spec/template/spec/restartPolicy
  value: Always
- op: add
  path: /metadata/annotations/checkov.io~1skip1
  value: "CKV_K8S_38=step-ca requires the service account token for the Kubernetes API when using the K8sSA provisioner."
- op: add
  path: /spec/template/metadata/annotations/secret.reloader.stakater.com~1reload
  value: "csi-driver-spiffe-ca"
```

- [ ] **Step 6.3: Create the Helm values file**

Key design decisions:
- `inject.enabled: true` provides the `ca.json` and `defaults.json` ConfigMaps only; cert/key come from `extraVolumes`.
- `ca.json` points `root`, `crt`, and `key` at `/home/step/external-certs/tls.crt` and `/home/step/external-secrets/tls.key` — paths that don't conflict with the chart's own `/home/step/certs/` and `/home/step/secrets/` mounts.
- `replicaCount: 1` — the step-certificates chart officially supports only one replica. HA is provided by CNPG (DB remains available) and Kubernetes pod restart on failure.
- The X5C provisioner trusts `csi-driver-spiffe-ca` and uses a certificate template that enforces `isCA: true`, `maxPathLen: 0`, and embeds the CRL distribution point in issued intermediate CA certificates.
- `PGPASSWORD` is injected from the CNPG-generated `step-ca-db-app` Secret.

Create `applications/step-ca/base/values.yaml`:
```yaml
replicaCount: 1

inject:
  enabled: true
  config:
    files:
      ca.json:
        root: /home/step/external-certs/tls.crt
        federateRoots: []
        crt: /home/step/external-certs/tls.crt
        key: /home/step/external-secrets/tls.key
        address: 0.0.0.0:9000
        insecureAddress: 0.0.0.0:9001
        dnsNames:
          - ca.crossplane.rye.ninja
          - step-certificates.step-ca.svc.cluster.local
          - 127.0.0.1
        logger:
          format: json
        db:
          type: postgresql
          dataSource: "postgresql://stepcas@step-ca-db-rw.step-ca.svc.cluster.local:5432/stepcas?sslmode=require"
        authority:
          claims:
            minTLSCertDuration: 5m
            maxTLSCertDuration: 8760h
            defaultTLSCertDuration: 8760h
            disableRenewal: false
          provisioners:
            - type: X5C
              name: x5c
              roots:
                - /home/step/external-certs/tls.crt
              claims:
                maxTLSCertDuration: 8760h
                defaultTLSCertDuration: 8760h
              options:
                x509:
                  template: |
                    {
                      "subject": {{ toJson .Subject }},
                      "sans": {{ toJson .SANs }},
                      "keyUsage": ["certSign", "crlSign"],
                      "basicConstraints": {
                        "isCA": true,
                        "maxPathLen": 0
                      },
                      "crlDistributionPoints": ["http://ca.crossplane.rye.ninja/1.0/crl"]
                    }
        crl:
          enabled: true
          generateOnRevoke: true
        tls:
          cipherSuites:
            - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
            - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
            - TLS_AES_128_GCM_SHA256
          minVersion: 1.2
          maxVersion: 1.3
          renegotiation: false
      defaults.json:
        ca-url: https://step-certificates.step-ca.svc.cluster.local
        ca-config: /home/step/config/ca.json
        fingerprint: ""
        root: /home/step/external-certs/tls.crt
  certificates:
    root_ca: ""
    intermediate_ca: ""
  secrets:
    x509:
      enabled: false
    ca_password: ""
    provisioner_password: ""

bootstrap:
  enabled: false

# Mount the ESO-synced csi-driver-spiffe-ca secret at custom paths that don't
# conflict with the chart's own /home/step/certs/ and /home/step/secrets/ mounts.
extraVolumes:
  - name: spiffe-ca-certs
    secret:
      secretName: csi-driver-spiffe-ca
  - name: spiffe-ca-secrets
    secret:
      secretName: csi-driver-spiffe-ca

extraVolumeMounts:
  - name: spiffe-ca-certs
    mountPath: /home/step/external-certs
    readOnly: true
  - name: spiffe-ca-secrets
    mountPath: /home/step/external-secrets
    readOnly: true

# DB password from CNPG-generated secret.
# lib/pq (step-ca's PostgreSQL driver) honors the PGPASSWORD environment variable.
extraEnv:
  - name: PGPASSWORD
    valueFrom:
      secretKeyRef:
        name: step-ca-db-app
        key: password
```

- [ ] **Step 6.4: Create the Backstage catalog entry**

Create `applications/step-ca/base/catalog.yaml`:
```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: step-ca
  description: |-
    Smallstep step-ca certificate authority with X5C provisioner,
    serving as the intermediate CA signing authority for workload
    clusters (ADR-7 Pattern D). Backed by a CNPG PostgreSQL cluster.
  tags:
    - certificates
    - pki
    - platform
    - infrastructure
spec:
  type: service
  lifecycle: production
  owner: platform-engineering
```

- [ ] **Step 6.5: Create the kustomization**

No global `namespace:` — resources span both `step-ca` and `cert-manager` namespaces, so each file declares its own namespace explicitly.

Create `applications/step-ca/base/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - resources/network-policy.yaml
  - resources/eso.service-account.yaml
  - resources/eso.cert-manager-role.yaml
  - resources/eso.cert-manager-rolebinding.yaml
  - resources/eso.secret-store.yaml
  - resources/eso.external-secret.yaml
  - resources/gateway.yaml
  - resources/tls-route.yaml
  - resources/http-route.yaml

helmCharts:
  - name: step-certificates
    repo: https://smallstep.github.io/helm-charts
    version: 1.30.1
    releaseName: step-certificates
    namespace: step-ca
    includeCRDs: false
    valuesFile: values.yaml

patches:
  - target:
      kind: Deployment
    path: patches/deployment.yaml

images:
  - name: cr.smallstep.com/smallstep/step-ca
    newTag: "0.30.2"
    digest: sha256:a2b17872915c193259b75a5474c398326f41bd199f0842093e52cf4182bc8270
  - name: cr.smallstep.com/smallstep/step-ca-bootstrap
    digest: sha256:5270356cf91596afe18478eab60c6c0866b2cc62618f282d42827e58f84d6eae
```

- [ ] **Step 6.6: Validate the application renders**

```bash
cd applications/step-ca/base && kustomize build --enable-helm .
```

Expected: YAML output including the Deployment, Service, ConfigMaps, Gateway, TLSRoute, HTTPRoute, and ESO resources — no errors.

- [ ] **Step 6.7: Commit**

```bash
git add applications/step-ca/
git commit -m "feat: add step-ca application with ESO root CA sync and Gateway API exposure"
```

---

## Task 7: Wire into `clusters/crossplane` and add hostname patch

**Files:**
- Modify: `clusters/crossplane/kustomization.yaml`
- Create: `clusters/crossplane/patches/step-ca.gateway.yaml`

- [ ] **Step 7.1: Add the cluster-specific Gateway hostname patch**

This sets the hostname for both listeners on the step-ca Gateway so ExternalDNS can create DNS records and Envoy Gateway can route by hostname.

```bash
mkdir -p clusters/crossplane/patches
```

Create `clusters/crossplane/patches/step-ca.gateway.yaml`:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: step-ca
  namespace: step-ca
spec:
  listeners:
    - name: https-passthrough
      hostname: ca.crossplane.rye.ninja
    - name: http-crl
      hostname: ca.crossplane.rye.ninja
```

- [ ] **Step 7.2: Add the four applications to `clusters/crossplane/kustomization.yaml`**

Open `clusters/crossplane/kustomization.yaml` and insert the four new application lines and the Gateway hostname patch. The new entries go after `cert-manager-spiffe-csi-driver` and before `crossplane`:

```yaml
  - ../../applications/cert-manager-spiffe-csi-driver/base   # existing

  - ../../applications/cnpg/base                             # new
  - ../../applications/envoy-gateway/base                    # new
  - ../../applications/step-ca-db/base                       # new
  - ../../applications/step-ca/base                          # new

  - ../../applications/crossplane/base                       # existing
```

Also add the Gateway hostname patch at the end of the `resources:` list (before the inline resources section, or after the last application line — whichever is cleaner given the existing file structure) and a `patches:` section if one doesn't exist:

```yaml
patches:
  - path: patches/step-ca.gateway.yaml
    target:
      kind: Gateway
      name: step-ca
      namespace: step-ca
```

- [ ] **Step 7.3: Validate the cluster kustomization renders**

```bash
cd clusters/crossplane && kustomize build --enable-helm .
```

Expected: Full cluster YAML output including all existing resources plus the four new applications — no errors.

- [ ] **Step 7.4: Commit**

```bash
git add clusters/crossplane/kustomization.yaml clusters/crossplane/patches/step-ca.gateway.yaml
git commit -m "feat: wire cnpg, envoy-gateway, step-ca-db, step-ca into crossplane cluster"
```

---

## Task 8: Full render validation

- [ ] **Step 8.1: Install render dependencies if needed**

```bash
make render-deps
```

Expected: kustomize and other tools installed to `.venv/bin/`.

- [ ] **Step 8.2: Run the full render**

```bash
make render-manifests
```

Expected: `.render/flux-platform-rendered/` populated with rendered YAML for all applications, including the four new ones — no errors.

- [ ] **Step 8.3: Verify the four new applications rendered**

```bash
ls .render/flux-platform-rendered/applications/cnpg/base/
ls .render/flux-platform-rendered/applications/envoy-gateway/base/
ls .render/flux-platform-rendered/applications/step-ca-db/base/
ls .render/flux-platform-rendered/applications/step-ca/base/
```

Expected: each directory contains `rendered.yaml`, `catalog.yaml`, and `kustomization.yaml`.

- [ ] **Step 8.4: Spot-check the step-ca rendered output**

Verify the ca.json ConfigMap references the external-certs mount path (not the chart default):

```bash
grep "external-certs\|external-secrets" .render/flux-platform-rendered/applications/step-ca/base/rendered.yaml
```

Expected: lines referencing `/home/step/external-certs/tls.crt` and `/home/step/external-secrets/tls.key`.

Verify the ExternalSecret and SecretStore rendered:

```bash
grep "kind: ExternalSecret\|kind: SecretStore\|kind: TLSRoute\|kind: HTTPRoute" \
  .render/flux-platform-rendered/applications/step-ca/base/rendered.yaml
```

Expected: one line each for `ExternalSecret`, `SecretStore`, `TLSRoute`, `HTTPRoute`.

- [ ] **Step 8.5: Commit the validated state**

```bash
git add .
git commit -m "chore: confirm render passes for cnpg, envoy-gateway, step-ca-db, step-ca"
```

---

## Notes for the Implementor

**Helm chart repo vs OCI:** The step-certificates chart is referenced via HTTPS (`https://smallstep.github.io/helm-charts`). kustomize's `--enable-helm` will download it at render time. If your environment is air-gapped or you prefer vendored charts (as the repo does for cert-manager), vendor it into `applications/step-ca/base/charts/step-certificates-1.30.1/` and remove the `repo:` field from the helmChart entry.

**replicaCount caveat:** The step-certificates chart officially supports only `replicaCount: 1`. If you experiment with higher replica counts after confirming the Postgres backend works, watch for step-ca startup errors related to concurrent DB initialization.

**CNPG app secret keys:** The `step-ca-db-app` Secret created by CNPG has the key `password` (not `PGPASSWORD`). The `extraEnv` in values.yaml reads it correctly as `secretKeyRef.key: password`.

**step-ca fingerprint:** `defaults.json` includes `fingerprint: ""`. After first deployment, retrieve the actual fingerprint with `kubectl exec -n step-ca <step-ca-pod> -- step ca root | step certificate fingerprint` and update the value. Clients (step-issuer) use this to verify the CA.

**CRL hostname:** `ca.crossplane.rye.ninja` is the hostname derived from ADR-16. Confirm it matches the `XDelegatedHostedZoneAWS` claim for the crossplane cluster before deploying.
