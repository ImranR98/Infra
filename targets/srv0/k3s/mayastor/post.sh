#!/bin/bash
set -euo pipefail

COMPONENT_DIR="${ATLAS_ROOT}/targets/${TARGET}/k3s/mayastor"

echo "Waiting for Mayastor CRDs..."
kubectl wait --for condition=established crd/diskpools.openebs.io --timeout=300s

echo "Creating DiskPools..."
envsubst "$ENVSUBST_VARS" < "$COMPONENT_DIR/pool-provisioner.yaml" | kubectl apply -f -
