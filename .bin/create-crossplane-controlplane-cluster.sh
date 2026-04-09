#!/bin/bash
CLUSTER_NAME=${CLUSTER_NAME:-crossplane-controlplane-cluster}
CNI=${CNI:-calico}
KUBERNETES_VERSION=${KUBERNETES_VERSION:-1.33.0}
NODEPOOL_CLASS=${NODEPOOL_CLASS:-ch}
NODEPOOL_TYPE=${NODEPOOL_TYPE:-vs2}
NODEPOOL_SIZE=${NODEPOOL_SIZE:-medium}
NODEPOOL_REGION=${NODEPOOL_REGION:-dfw2}
ORG=${ORG:-ryezone-labs}
REGION=${REGION:-us-central-dfw-2}


spotctl cloudspaces create \
  --cni $CNI \
  --kubernetes-version $KUBERNETES_VERSION \
  --ondemand-nodepool desired=1,serverclass=${NODEPOOL_CLASS}.${NODEPOOL_TYPE}.${NODEPOOL_SIZE}-${NODEPOOL_REGION} \
  --org $ORG \
  --region $REGION \
  --name $CLUSTER_NAME