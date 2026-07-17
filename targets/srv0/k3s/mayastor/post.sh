#!/bin/bash
set -euo pipefail

source "$ATLAS_ROOT/lib/common.sh"

COMPONENT_DIR="${ATLAS_ROOT}/targets/${TARGET}/k3s/mayastor"

echo "Waiting for Mayastor CRDs..."
retry 60 5 "kubectl get crd diskpools.openebs.io >/dev/null"
kubectl wait --for condition=established crd/diskpools.openebs.io --timeout=300s 2>/dev/null || true

echo "Creating DiskPools..."
envsubst "$ENVSUBST_VARS" < "$COMPONENT_DIR/pool-provisioner.yaml" | kubectl apply -f -
