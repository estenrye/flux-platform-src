# 3. Bootstrapping the Crossplane Controlplane Cluster

Date: 2026-04-08

## Status

Accepted

## Context

I want to utilize GitOps practices to manage the provisioning and configuration of Kubernetes Clusters and the applications running on them across multiple cloud providers and on-premises environments.  I have seen many videos about Crossplane and want to experiment with it as a potential solution for this capability.  I want to use Flux and GitOps practices to bootstrap a Crossplane Controlplane cluster.

The infrastructure platforms that I want to manage with this cluster include:
- AWS EKS
- OCI OKE
- Azure AKS
- GCP GKE
- Rackspace Spot
- On-Premises KVM Hypervisors
- On-Premises OpenStack Clouds
- Wasabi Cloud Object Storage
- TrueNAS Scale Storage Server

## Decision

To operate the Crossplane Controlplane cluster as cheaply as possible, I will deploy it to Rackspace Spot.  I will use the Flux Operator to manage the configuration of the cluster and the Crossplane Operator to manage the provisioning and configuration of the target cluster infrastructure.

## Implementation Plan

- Provision a Kubernetes cluster on Rackspace Spot using spotctl.
- Install the Flux Operator to manage the configuration of the cluster using GitOps practices.

## Bootstrapping the Cluster

```bash
# Provision the cluster on Rackspace Spot
./.bin/create-crossplane-controlplane-cluster.sh


```