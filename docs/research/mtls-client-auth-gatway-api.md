# Feasibility: per-customer Envoy Gateways with customer-controlled mTLS CAs (no WireGuard)

**Date:** 2026-10-24
**Question:** Can we give each customer a dedicated Gateway whose client
certificate trust anchor is a CA the customer controls (an ACME-capable
private CA), so customers reach their endpoints securely over the public
internet without us building a WireGuard VPN?

## Verdict

**Feasible for HTTP(S) endpoints, with the repo's current stack (Envoy Gateway
1.8.1). It needs no new controller.** The gateway side is a stock
`ClientTrafficPolicy` plus a CA bundle. Real work remains in four places:

1. Getting the customer's CA root into a ConfigMap and keeping it current.
2. Revocation. Envoy Gateway only takes a *static* CRL, so short-lived client
   certs are the practical answer.
3. Non-HTTP protocols (SSH, kube-apiserver, databases). These are not covered
   by the simple path.
4. Pre-authentication attack surface on a public listener, which a VPN would
   have hidden.

"ACME" is a property of the customer's CA, not of the gateway. Envoy only
needs a root/intermediate PEM, so ACME matters only for how customers issue
and renew client certs. Section 3 covers the one real ACME wrinkle.

What I verified and what I did not:

- **Verified in this repo:** the `ClientTrafficPolicy` schema in the vendored
  1.8.1 CRDs
  (`applications/envoy-gateway/base/charts/gateway-helm-1.8.1/.../gateway.envoyproxy.io_clienttrafficpolicies.yaml`),
  and the existing gateway/issuer layout.
- **Verified from upstream docs:** the basic mTLS flow
  ([Envoy Gateway mutual TLS task](https://gateway.envoyproxy.io/docs/tasks/security/mutual-tls)).
- **Not tested:** nothing has been deployed. Items marked **[test]** need a PoC.

## 1. What the platform gives us today

- Envoy Gateway 1.8.1, with GatewayClasses `merged-eg` (controlplane and
  observability) and `internal-eg` (controlplane). `merged-eg` points at
  `EnvoyProxy/custom-proxy-config`, which sets `mergeGateways: true`.
  Calico also ships `internal-dedicated`, `external-dedicated`,
  `internal-merged` and `external-merged` classes
  (`applications/calico/base/resources/envoy-proxy-config.yaml`).
- IPv6-only LoadBalancer Services, with addresses from Calico LB IPAM via the
  `projectcalico.org/ipv6pools: lb-ingress-routed` annotation.
- cert-manager with the Gateway API shim enabled. `netdata`'s Gateway already
  gets a Let's Encrypt server cert from the `cert-manager.io/cluster-issuer`
  annotation (`applications/netdata/base/resources/gateway.yaml`).
- An existing mTLS pattern that does **not** use Envoy: `openbao` and
  `step-ca` use TLS *passthrough* and verify client certs in the backend
  (`applications/openbao/base/resources/gateway.yaml`).
- No `ClientTrafficPolicy` with `clientValidation` exists in the repo yet.
- No Gateway uses an external class yet (see
  `docs/memory/external-gateway-header-sanitization-deferred.md`).
  Customer-facing Gateways would be the first, which triggers that deferred
  header-sanitization work.

## 2. The gateway-side mechanism

`ClientTrafficPolicy.spec.tls.clientValidation` (1.8.1 CRD) supports:

| Field | Use here |
|---|---|
| `caCertificateRefs` | Customer CA root (and intermediates). A ConfigMap or Secret with key `ca.crt`. Cross-namespace needs a `ReferenceGrant`. |
| `mode` | `RequireAndVerify` (default), `VerifyIfGiven`, `Request`, `RequireAny`. We want `RequireAndVerify`. |
| `subjectAltNames` | Match on `dnsNames`, `emailAddresses`, `ipAddresses`, `uris`, `otherNames`. Narrows which identities in the customer's CA are accepted. |
| `spkiHashes` / `certificateHashes` | Pin specific keys or certs. Strong, but operationally heavy. |
| `crl.refs` | CRL from a ConfigMap or Secret, with `onlyVerifyLeafCertificate`. Static content: Envoy does not fetch CDP URLs. |

The policy targets a `Gateway` (optionally a `sectionName` listener) through
`targetRefs`. Client certs are validated during the TLS handshake, before any
HTTP processing.

**Identity to the backend.** `spec.headers.xForwardedClientCert` supports
`SanitizeSet` and `AppendForward` with `certDetailsToAdd`. Use `SanitizeSet`
so clients cannot spoof the header, and let the backend (or a
`SecurityPolicy`) authorize on the SAN/subject.

**Sketch (one customer):**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: acme-corp
  namespace: cust-acme-corp
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod   # server cert: public CA
spec:
  gatewayClassName: customer-dedicated                # non-merged class
  infrastructure:
    parametersRef:                                    # per-customer EnvoyProxy
      group: gateway.envoyproxy.io
      kind: EnvoyProxy
      name: acme-corp-proxy
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: acme-corp.access.example.net
      tls:
        mode: Terminate
        certificateRefs: [{kind: Secret, name: acme-corp-tls}]
      allowedRoutes:
        namespaces: {from: Same}
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: acme-corp-mtls
  namespace: cust-acme-corp
spec:
  targetRefs:
    - {group: gateway.networking.k8s.io, kind: Gateway, name: acme-corp}
  tls:
    minVersion: "1.3"
    clientValidation:
      mode: RequireAndVerify
      caCertificateRefs:
        - {kind: ConfigMap, name: acme-corp-client-ca}   # key: ca.crt
      subjectAltNames:
        dnsNames: [{type: Suffix, value: .clients.acme-corp.example}]
  headers:
    xForwardedClientCert:
      mode: SanitizeSet
      certDetailsToAdd: [Subject, URI, DNS]
  connection:
    connectionLimit: {value: 500}
```

Field names above are checked against the CRD except the nested
`subjectAltNames` match-type shape and the `connection` block. Check both
against the CRD before committing.

## 3. The ACME wrinkle: client certs from an ACME CA

ACME (RFC 8555) is built to prove control of DNS names or IPs for **server**
certs. Three consequences:

- **Public ACME CAs (Let's Encrypt etc.) are not an option for client auth.**
  Public root programs have been removing `clientAuth` EKU from publicly
  trusted server certs. Even where one issued it, the whole internet would
  trust the issuer, so any holder of any such cert would pass the handshake.
  The trust anchor must be a *private* CA scoped to one customer. This is
  from my background knowledge and was not re-verified in this session.
- **A customer-run private CA with an ACME endpoint works.** Examples are
  step-ca (we already run one for the platform), Vault/OpenBao PKI, and
  EJBCA. Client certs are issued against DNS-style identifiers, with the
  `clientAuth` EKU set by the CA's template. step-ca also offers
  `device-attest-01` for device-bound client certs, which is stronger
  ([ACME Basics](https://smallstep.com/docs/step-ca/acme-basics/)). That
  challenge is still an IETF draft
  ([draft-ietf-acme-device-attest](https://datatracker.ietf.org/doc/draft-ietf-acme-device-attest/)).
- **cert-manager on the customer side is unverified.** I found nothing
  confirming that cert-manager's ACME issuer can request client-auth certs.
  Customers can use `step`, certbot or acme.sh against their own CA instead.
  **[test]** if you plan to recommend cert-manager.

Two ways to host the CA:

| | Customer-run CA | Platform-hosted per-customer CA (step-ca instance or provisioner) |
|---|---|---|
| Control | Full | Customer controls the provisioner policy, we operate it |
| Our burden | Only ingest the root PEM | Run, back up and rotate a CA per customer |
| Key-compromise blast radius | Their CA, their gateway only | Same, plus our operational risk |
| Fit | Matches "customer controlled" | Better for customers with no PKI |

Recommendation: default to customer-run. Offer hosted only as an add-on.

## 4. Dedicated vs. shared gateways

Because trust is configured per Gateway (or listener), a customer CA can
never authenticate to another customer's endpoints as long as the policies
are scoped correctly.

- **Dedicated Gateway per customer** (non-merged class plus a per-Gateway
  `EnvoyProxy` via `infrastructure.parametersRef`): own Deployment, own
  Service and LB address, own NetworkPolicy, own scaling and resource limits.
  A misconfigured policy or noisy customer can't affect others. Cost: at
  least two Envoy pods per customer (the current proxies run 2 replicas
  with anti-affinity) and one address each. Addresses are cheap on IPv6.
  Pod count is the real cost, given the capacity pressure noted in
  `docs/memory/m4-design.md`.
- **Shared data plane, per-listener trust** (`merged-eg` plus one listener
  and one `sectionName`-targeted `ClientTrafficPolicy` per customer, SNI
  selects the filter chain): cheaper, but a bad policy attachment or Envoy
  crash touches everyone. Shared fate is the problem, not trust leakage.
- **Recommendation:** dedicated, since the requirement is explicitly
  "dedicated gateways", and keep a GatewayClass such as `customer-dedicated`
  with `mergeGateways` unset. **[test]** that a per-Gateway `EnvoyProxy`
  sets the Calico pool annotation correctly, so each gateway gets an address
  from the intended pool.

## 5. Risks and gaps

1. **CA ingestion and rotation.** The CA lives in a ConfigMap or Secret. The
   CRD text says a *single* reference is currently supported, while the
   schema allows up to 8. **[test]** multiple refs, because CA rollover
   needs old and new trusted together, or else put both roots in one
   `ca.crt` bundle. Nothing here fetches a customer's CA from a URL.
   trust-manager syncs in-cluster sources, so a small CronJob, or a customer
   push through GitOps or an API, would be needed. **[test]** that a
   ConfigMap update reaches Envoy without restarting pods.
2. **Revocation.** `crl.refs` is static. Two workable approaches:
   - Require short-lived client certs (hours to days) and rely on expiry.
     This pairs naturally with ACME renewal.
   - Run a sync job that republishes the customer's CRL into the ConfigMap.
   Do not assume OCSP, as I found no support for it.
3. **Authorization is separate from authentication.** "Signed by the
   customer's CA" is not "allowed to call this route". Use
   `subjectAltNames` to constrain identities, and add a `SecurityPolicy`
   (authorization by client-cert SAN) or backend checks for per-route access
   control. **[test]** what `SecurityPolicy` can key on for cert identity in
   1.8.1.
4. **Non-HTTP protocols.** The `clientValidation` path above is tested only
   for HTTPS listeners. Passthrough listeners (the `openbao`/`step-ca` style)
   can't be validated by Envoy at all, so the backend must verify client
   certs itself. For SSH or other TCP services the mTLS-at-gateway model
   doesn't apply directly. The tools in
   `docs/research/ssh-gateway-and-k8s-combined.md` (Teleport and similar)
   solve that with reverse tunnels, not WireGuard. **[test]** whether
   `clientValidation` applies to TLS-terminate listeners used with
   `TLSRoute`/`TCPRoute`.
5. **Public pre-auth surface.** A VPN hides the service. A public listener
   exposes the TLS handshake to the internet. Mitigate with:
   - TLS 1.3 minimum.
   - Connection limits and handshake/idle timeouts in the
     `ClientTrafficPolicy`.
   - Optional IP allow-lists via `SecurityPolicy` where customers have
     static egress.
   - An upstream L3/L4 control (UniFi firewall or a CDN with mTLS pass
     through). Note a CDN that terminates TLS breaks client-cert auth.
6. **Header hygiene.** Customer-facing gateways are the first external
   gateways, so the deferred header-sanitization work (strip inbound
   `traceparent`, `tracestate` and `baggage` via
   `headers.earlyRequestHeaders.remove`) lands here. Add it to the same
   `ClientTrafficPolicy`. Also use `SanitizeSet` for XFCC.
7. **Customer CA mistakes become our incidents.** Customers who issue
   overly broad certs (a wildcard, or a CA shared with other tenants)
   weaken only their own gateway, but support burden is ours. Document SAN
   conventions and require `subjectAltNames` matching.
8. **Server-cert pathway.** Let's Encrypt `dns01` via Cloudflare is already
   wired (`letsencrypt-prod` ClusterIssuer). Customer hostnames in our zone
   work directly. Customer-owned domains need delegation or an HTTP-01
   solver, which is a separate decision.

## 6. mTLS vs. WireGuard

| | mTLS at gateway | WireGuard |
|---|---|---|
| Client software | None for browsers and API clients (cert install only) | Agent plus config per user/site |
| Protocols | HTTP(S) cleanly; others awkward | Anything routable |
| Identity | Per-connection, per-cert, visible in access logs | Per-peer key; per-user needs extra layers |
| Network exposure | Public listener | Hidden behind UDP key auth |
| Revocation | Short-lived certs or static CRL | Remove the peer |
| Audit | L7 access logs already in place (JSON, trace_id) | L3/L4 only |
| Ops cost for us | One Gateway, policy and bundle per customer | Peer management, routing, IPv6/NAT64 concerns |

mTLS fits web and API access. If SSH or database access is also required, it
needs a protocol-aware companion (see the SSH research doc), not a VPN.

## 7. Suggested PoC (about a day)

1. In a scratch namespace on `core-infra`, create a `customer-dedicated`
   GatewayClass (no `mergeGateways`) and a per-Gateway `EnvoyProxy` with the
   Calico pool annotation.
2. Stand up a throwaway step-ca (or `step certificate create`) acting as the
   "customer CA". Publish its root as a ConfigMap `ca.crt`.
3. Apply the Gateway and `ClientTrafficPolicy` from section 2, with a
   trivial echo backend behind an `HTTPRoute`.
4. Prove: valid client cert gives 200; no cert fails the handshake; a cert
   from a *different* CA fails; a cert with a non-matching SAN fails.
5. Prove rotation: add a second root, then drop the first, with no pod
   restart. Test both multiple `caCertificateRefs` and a combined bundle.
6. Prove revocation: publish a CRL ConfigMap and revoke a cert.
7. Check XFCC reaches the backend with `SanitizeSet`, and that a
   client-supplied XFCC header is overwritten.
8. Measure the pod and address cost of one dedicated gateway to decide
   dedicated vs. shared at your expected customer count.

## Sources

- [Envoy Gateway: Mutual TLS, external clients to the Gateway](https://gateway.envoyproxy.io/docs/tasks/security/mutual-tls)
- [Envoy Gateway: Client Traffic Policy](https://gateway.envoyproxy.io/docs/concepts/gateway_api_extensions/client-traffic-policy/)
- [Smallstep: ACME Basics (device-attest-01)](https://smallstep.com/docs/step-ca/acme-basics/)
- [IETF draft: ACME device attestation](https://datatracker.ietf.org/doc/draft-ietf-acme-device-attest/)
- Repo: vendored `clienttrafficpolicies` CRD (1.8.1),
  `applications/calico/base/resources/envoy-proxy-config.yaml`,
  `applications/netdata/base/resources/gateway.yaml`,
  `applications/openbao/base/resources/gateway.yaml`
