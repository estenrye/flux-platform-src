# Research: Ad-Hoc Command Execution Platform for Multi-Cloud Kubernetes

**Date:** 2026-07-30
**Requirements:** cloud/virtualization-agnostic K8s command execution; OIDC for humans; OIDC on-behalf-of for AI agents; audit tracing to human/agent identity; risk-based command rules; traces/logs/metrics; surfacing of common commands for pattern generalization.

## 1. Core Execution Gateways (identity-aware command proxies)

These sit between users/agents and the K8s API, and are the strongest single-product fits.

**Teleport** (open core + enterprise) — Identity-aware proxy and CA issuing short-lived certs from OIDC/SAML identity. Unified access for kubectl, SSH, DBs, and apps; full session recording and replay; RBAC; just-in-time access requests; moderated sessions (human approval for risky operations). Its MCP Access Controls extend the same identity, policy, and audit model to AI-agent tool calls — the closest match to your dual human/agent consumer model. Best overall candidate.

**Hoop.dev** (commercial, self-hostable) — Command-level proxy purpose-built for governed ad-hoc execution. OIDC auth, per-command rules enforced in the proxy layer (blocks destructive/noncompliant commands pre-execution), AI-driven PII masking of output, structured audit logs tied to user identity, review/approval workflows. Explicitly positions as a gateway for AI agents. Strong fit for the rules-framework requirement.

**StrongDM** (commercial) — Control plane for K8s, DB, and server access with JIT approvals, full session/query logging, and policy-based access. Mature enterprise option; less AI-agent-native than Teleport/Hoop.

**Paralus** (CNCF Sandbox, fully OSS) — kubectl proxy with OIDC SSO, JIT service-account creation, and immutable audit of every kubectl command. Uses Ory Kratos + Casbin. Good free baseline if you want to build the rules/agent layers yourself; lighter on session recording and policy depth.

**HashiCorp Boundary** (open core) — Identity-aware proxy with Vault credential injection. Solid access broker but weaker K8s command-level audit/policy than the above.

**Pomerium / Border0** — Pomerium: per-request authZ and audit for HTTP services, K8s API access supported; Border0 (session recording, command visibility) was acquired by Tailscale. Secondary options.

## 2. AI Agent Layer (on-behalf-of execution)

**Pattern to implement:** OAuth 2.0 Token Exchange (RFC 8693) — agent exchanges the user's token for a downscoped token asserting "Agent X acting for User Y" (actor claim), preserving both identities for audit. This is the emerging standard for MCP/agent auth.

**agentgateway** (OSS, Solo.io/Linux Foundation) — Gateway for MCP/A2A traffic; performs RFC 8693 token exchange, authZ policy, and telemetry for agent tool calls.

**kagent** (CNCF) — Kubernetes-native agent runtime with tools/agents/framework layers; MCP integration; the enterprise version adds identity and governance for agents. Candidate for running your diagnostic agents themselves.

**Botkube** — K8s AI assistant in Slack/Teams with per-plugin RBAC and executed-command notifications; **Kubiya** — ChatOps agents with RBAC. Both are faster to adopt but less rigorous on delegated identity than the token-exchange pattern.

## 3. Identity & Delegation Infrastructure

**Keycloak** or **Dex** as OIDC provider — Keycloak has first-class RFC 8693 token exchange for the on-behalf-of flow. Kubernetes natively accepts OIDC tokens (structured authentication config), and **user impersonation** headers let a gateway act as the real user so K8s audit logs show the human identity. **SPIFFE/SPIRE** for workload identity of the agent applications themselves across clouds/on-prem.

## 4. Rules / Risk Framework

**OPA (Rego)** — General-purpose policy engine; embed in your gateway to score command risk (verb, resource, namespace, environment, requester type) and allow/deny/require-approval. **OPA Gatekeeper** or **Kyverno** at the admission layer can additionally restrict `pods/exec` CONNECT operations cluster-side as defense in depth. **Cerbos** is an alternative decision-point engine with good agent/zero-trust patterns. Teleport (moderated sessions, access requests) and Hoop.dev (command guardrails) ship this capability built-in.

## 5. Audit, Traces, Logs, Metrics

Kubernetes API **audit logging** (with impersonation, attributes both gateway and end user) + gateway session recordings as the audit backbone. **OpenTelemetry** for traces/metrics of every command execution, shipped to **Prometheus/Loki/Grafana** or your existing stack. **Falco** for runtime detection of what exec'd commands actually did inside containers. Command-frequency analytics over the audit stream is how you surface candidates for generalization.

## 6. Pattern Generalization (ad-hoc → curated runbooks)

Once common commands surface, promote them to parameterized, pre-approved jobs: **PagerDuty Runbook Automation (Rundeck)** — self-service jobs with ACLs and audit; **StackStorm** (OSS) — event-driven automation with ChatOps; **Ansible Automation Platform**; **Kestra** as a modern OSS orchestrator. These become the low-risk path that replaces ad-hoc execution over time.

## Suggested Shortlist

| Need | First choice | Alternative |
|---|---|---|
| Execution gateway + audit + session recording | Teleport | Hoop.dev, StrongDM |
| OSS-only baseline | Paralus + OPA | Boundary |
| Agent on-behalf-of auth | Keycloak token exchange + agentgateway | Teleport MCP Access Controls |
| Command risk rules | Hoop.dev guardrails or OPA in-gateway | Kyverno/Gatekeeper (admission) |
| Observability | OTel + K8s audit + Falco | vendor-native (Teleport audit) |
| Generalized runbooks | Rundeck/PagerDuty RBA | StackStorm, Kestra |

**Recommended architecture to prototype:** OIDC IdP (Keycloak) → identity-aware gateway (Teleport or Hoop.dev) with RFC 8693 token exchange for agents → OPA policy decision point for risk scoring → K8s impersonation so cluster audit logs carry true identity → OTel pipeline for traces/metrics → periodic analysis of command frequency feeding a Rundeck/StackStorm runbook catalog.

## Sources

- [Teleport: Kubernetes for Agentic AI — Identity and Access](https://goteleport.com/blog/kubernetes-agent-identity-access/)
- [Teleport: Kubernetes for Agentic AI — Security and Observability](https://goteleport.com/blog/kubernetes-for-agentic-ai/)
- [StrongDM: Teleport alternatives comparison](https://www.strongdm.com/blog/alternatives-to-gravitational-teleport)
- [Hoop.dev](https://hoop.dev/) · [Kubernetes command governance](https://hoop.dev/blog/how-hipaa-safe-database-access-and-kubernetes-command-governance-allow-for-faster-safer-infrastructure-access) · [Structured audit logs](https://hoop.dev/blog/how-structured-audit-logs-and-cloud-native-access-governance-allow-for-faster-safer-infrastructure-access/)
- [Paralus](https://www.paralus.io/) · [Zero Trust K8s access with Paralus](https://www.infracloud.io/blogs/zero-trust-security-kubernetes-access-paralus/)
- [StrongDM JIT Kubernetes access](https://www.strongdm.com/resources/just-in-time-kubernetes-access-with-strongdm-secure-eks-aws-on-prem-clusters)
- [Pomerium Kubernetes access](https://www.pomerium.com/kubernetes-access) · [Border0 joins Tailscale](https://tailscale.com/blog/border0-joins-tailscale)
- [Keycloak + RFC 8693 token exchange for MCP](https://hrittikhere.com/posts/build-secure-mcp-server-keycloak-rfc8693) · [MCP on-behalf-of token exchange discussion](https://github.com/modelcontextprotocol/modelcontextprotocol/issues/214)
- [agentgateway](https://agentgateway.dev/docs/kubernetes/latest/reference/release-notes/) · [Red Hat: MCP gateway authN/authZ](https://developers.redhat.com/articles/2025/12/12/advanced-authentication-authorization-mcp-gateway)
- [kagent (CNCF)](https://www.cncf.io/blog/2025/04/15/kagent-bringing-agentic-ai-to-cloud-native/) · [kagent GitHub](https://github.com/kagent-dev/kagent) · [Solo Enterprise for kagent](https://www.solo.io/blog/kagent-enterprise)
- [Botkube RBAC](https://docs.botkube.io/features/rbac/) · [Kubiya Kubernetes Crew](https://www.kubiya.ai/blog/ai-agents-for-kubernetes)
- [Restricting kubectl exec with Gatekeeper](https://medium.com/@javier-canizalez/policy-enforcement-in-kubernetes-restricting-kubectl-exec-with-gatekeeper-7e99823465c9) · [Kyverno vs OPA](https://araji.medium.com/kubernetes-policy-as-code-kyverno-vs-opa-e44e0d613d8a)
- [Cerbos: MCP and Zero Trust](https://www.cerbos.dev/blog/mcp-and-zero-trust-securing-ai-agents-with-identity-and-policy)
- [Rundeck alternatives (Kestra)](https://kestra.io/resources/infrastructure/rundeck-alternatives) · [CNCF cloud-native agentic standards](https://www.cncf.io/blog/2026/03/23/cloud-native-agentic-standards/)
