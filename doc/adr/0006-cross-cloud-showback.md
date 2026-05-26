# 6. Cross Cloud Showback

Date: 2026-05-14

## Status

Proposed

## Context

I need a mechanism to track and report on cross-cloud resource usage and costs across our multi-cloud Kubernetes clusters. This will help us understand our cloud spend, identify optimization opportunities, and provide transparency to stakeholders.

There are several existing tools and approaches for cloud cost management, but I want to evaluate them in the context of our specific multi-cloud Kubernetes environment. The solution should be able to aggregate data from multiple clusters, support various cloud providers, and provide actionable insights.

There are also organizational and process considerations, such as how to integrate cost reporting into our existing workflows and how to ensure that the data is accurate and up-to-date.

OpenCost provides a great open-source [specification for cloud cost management](https://opencost.io/docs/specification), and there are several implementations of this specification, including Kubecost. I will need to evaluate these tools to see which one best fits our needs.

### Categories of Meterable Consumption

- Compute (CPU, Memory)
- Storage (Persistent Volumes)
- Network (Ingress/Egress)

#### Compute

Most resource consumption in Kubernetes is related to compute resources, which are typically measured in terms of CPU and memory usage. This can be tracked at the pod level, node level, or even at the cluster level.

The units of measurement for compute resources have two drivers:

**Provisioned CPU and Memory**

Defined by the resource requests set in the pod specifications, and represents the guaranteed CPU and memory resources allocated to the pod.

These values are also used to make scheduling decisions about which node to place the pod on and node auto-scaling decisions that increase or decrease the total provisioned resources for the cluster.

Units of measurement for provisioned resources.
  - CPU: Measured in millicores (m) or cores (1 core = 1000m)
  - Memory: Measured in bytes (B), with common units like MiB, GiB, etc.

Affinity, anti-affinity, taints, and tolerations rules ensure that pods are distributed across nodes for high availability, target specific resource requirements, and/or to prevent resource contention.  These rules can be based on labels, topology, or other criteria.  This can impact the overall resource consumption and cost, as it may lead to more efficient use of resources or, conversely, to over-provisioning if not configured correctly.

Provisioned resources can also be correlated with node operation costs to visualize the potential minimum cost of running the workloads under minimum load conditions, which can help with budgeting and forecasting.

**Actual usage of CPU and Memory**

Measured by the metrics server or other monitoring tools, and represents the actual CPU and memory usage of the pods. This can fluctuate over time based on the workload and can be used to identify underutilized resources or to optimize resource allocation.

This measurement is important for cost optimization, as it can help identify opportunities to reduce costs by right-sizing resources or by using more cost-effective instance types.

Resource utilization can be measured as a percentage of the provisioned resources, and can be used to identify trends and patterns in resource usage over time.

Actual usage can also be correlated with node operation costs to visualize the potential maximum cost of running the workloads under peak load conditions, which can help with budgeting and forecasting.

**Provisioned Burst CPU and Memory**

Defined by the resource limits set in the pod specifications, and represents the maximum CPU and memory resources that the pod can burst to before being throttled or OOM-killed.

These values are not used to make scheduling decisions about which node to place the pod on and are not considered when making node auto-scaling decisions that increase or decrease the total provisioned resources for the cluster.

Units of measurement for provisioned burst resources.
  - CPU: Measured in millicores (m) or cores (1 core = 1000m)
  - Memory: Measured in bytes (B), with common units like MiB, GiB, etc.

Provisioned burst resources control our oversubscription strategy for the compute nodes, allowing us to provision more resources than the actual capacity of the cluster, with the expectation that not all pods will use their maximum resources at the same time. This can lead to cost savings by allowing us to run more workloads on the same cluster, but it also introduces the risk of resource contention and performance degradation if too many pods try to burst at the same time.

Provisioned burst resources can be correlated with actual usage to identify patterns of resource consumption and to optimize the configuration of resource limits for better cost management.

Provisioned burst resources can also be correlated with node operation costs to visualize the potential maximum cost of running the workloads under peak load conditions, which can help with budgeting and forecasting.

#### Storage

Storage resources in Kubernetes are typically measured in terms of the amount of storage provisioned for Persistent Volumes (PVs) and the actual usage of that storage. This can be tracked at the PV level, Persistent Volume Claim (PVC) level, or even at the cluster level.
The units of measurement for storage resources are typically in bytes (B), with common units like MiB, GiB, etc.

Provisioned storage is defined by the storage class and the PVC specifications, and represents the amount of storage and performance profile that has been allocated for a particular workload. This can be used to calculate the cost of storage based on the pricing model of the cloud provider.

Actual storage usage can be measured by monitoring tools that track the amount of data stored in the PVs, the number of read/write operations, and the performance characteristics of the storage. This can be used to identify underutilized storage resources or to optimize storage allocation.

Provisioned storage can also be correlated with storage costs to visualize the potential minimum cost of running the workloadss, which can help with budgeting and forecasting.  Most storage costs are based on provisioned storage, but some cloud providers also charge for actual usage, so it's important to track both metrics for accurate cost management.

Actual storage usage can be correlated with node operation costs to visualize the waste cost incurred by unutilized storage, which can help with budgeting and forecasting.  It is important to track actual storage usage to identify opportunities for cost optimization, such as deleting unused PVs or resizing PVCs to better match the actual storage needs of the workloads.  However, it's important to consider the usage and growth patterns of the workloads when making decisions about storage optimization, as deleting PVs or resizing PVCs can lead to data loss or performance degradation if not done carefully.

#### Network

Network usage in Kubernetes are typically measured in terms of the amount of data transferred in and out of the cluster, as well as the number of network requests made by the workloads. This can be tracked at the pod level, service level, or even at the cluster level. The units of measurement for network resources are typically in bytes (B) for data transfer, and in requests per second (RPS) for network requests.

Network usage is measured at the pod level by monitoring tools that track the amount of data transferred in and out of the pods, as well as the number of network requests made by the workloads. This can be used to identify patterns of network usage and to optimize network configuration for better cost management.  Cloud providers typically charge for data transfer between different regions, availability zones, and/or to the Internet, so it's important to track network usage to identify opportunities for cost optimization, such as using more efficient network architectures or optimizing data transfer patterns.

Observability tooling should be able to correlate network usage with pod and node labels enabling visibility of
  - what workloads are generating traffic on the network.
  - where the traffic is flowing to and from (e.g. traffic in the same az, same region, different az, different region, or to/from the Internet).
  - how much data is being transferred and how many requests are being made.

This information can be used to optimize network configuration, such as using more efficient network architectures or optimizing data transfer patterns, to reduce costs and improve performance.

## Decision

No implementation decision has been made yet, but the following options are being considered:
- OpenCosts (https://opencost.io/)
- Kubecost (https://www.kubecost.com/)

## Consequences

- We have identified the primary categories of consumption that any showback solution must measure across clusters: compute, storage, and network.
- This makes it easier to evaluate OpenCost, Kubecost, and other implementations against a common set of multi-cloud Kubernetes requirements.
- No implementation has been selected yet, so delivery of cross-cloud showback remains blocked until tool evaluation and rollout decisions are completed.
- There is a risk that different cloud providers and Kubernetes environments will expose cost and usage data with different levels of fidelity, which may reduce accuracy or comparability of reports.
- There is a risk that integrating cost data into existing operational workflows will require additional engineering effort and process changes; mitigation is TBD pending tool selection.
- There is a risk that network and shared resource allocation may be difficult to attribute consistently across clusters, namespaces, and teams; acceptable allocation rules are TBD.
