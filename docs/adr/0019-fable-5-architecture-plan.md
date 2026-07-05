# 19. Fable 5 Architecture Plan

Date: 2026-07-05

## Status

Draft

## Prompt

You are a principal platform engineering architect and you are designing an architecture for a Crossplane based controlplane that will manage a fleet of Kubernetes clusters across an on-premise home lab running kvm, Ubiquiti Network 10.5 and TrueNAS Scale, and a fleet of cloud clusters running on AWS, GCP, OCI, and Azure.  The primary goal of this architecture is to provide a unified controlplane for managing the lifecycle of all clusters, including provisioning, configuration, and monitoring.  The architecture should avoid lock-in to the platform of any one cloud vendor, and opt for self-hosting core services like identity, monitoring, databases, security, observability and messaging when doing so improves the vendor agnosticism of the system as a whole.  When making these decisions, trade-offs should be carefully considered and selected solutions should use interoperable protocols like OpenTelemetry, OIDC and similar generally accepted protocols such that they can be swapped for other tools if we choose to do so.  The architecture should also support multi-tenancy, RBAC, and secure communication between the controlplane and managed clusters.  Workload Identity Federation (WIF) should be used to provide a unified identity and access management solution across all clusters, and the architecture should support the use of SPIFFE for workload identity and secure communication.  The architecture must also support the use of GitOps via Flux for managing the configuration of all clusters, and should provide a unified observability solution for monitoring the health and performance of all clusters.  The plan you produce should be detailed enough to serve as a blueprint for implementing the architecture using Sonnet 4.6.  The plan should also include a roadmap for implementing the architecture, including milestones, timelines, and resource requirements.

## Memory

You can use my openbrain mcp services to store and retrieve memory.  My openbrain has a knowledge graph in addition to a vector database for thoughts.  I want you to tag your thoughts, nodes and edges with `environment=home-lab` and `project=flux-platform` and `model=fable-5` so that I can query them later.  I want you to store your thoughts in my openbrain mcp services as you have them, and retrieve them when you need to reference them.  I want you to use the knowledge graph to reason about your thoughts and the vector database to find similar thoughts.

