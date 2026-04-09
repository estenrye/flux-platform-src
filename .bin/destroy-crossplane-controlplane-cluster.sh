#!/bin/bash
CLUSTER_NAME=${CLUSTER_NAME:-crossplane-controlplane-cluster}
ORG=${ORG:-ryezone-labs}


spotctl cloudspaces delete \
  --org $ORG \
  --name $CLUSTER_NAME \
  --yes