#!/bin/bash
set -euo pipefail

COMPONENT_DIR="${ATLAS_ROOT}/targets/${TARGET}/k3s/mayastor"

echo "Waiting for Mayastor CRDs..."
for i in $(seq 1 60); do
	if kubectl get crd diskpools.openebs.io >/dev/null 2>&1; then
		kubectl wait --for condition=established crd/diskpools.openebs.io --timeout=30s 2>/dev/null && break
	fi
	sleep 5
done

echo "Creating DiskPools..."
envsubst "$ENVSUBST_VARS" < "$COMPONENT_DIR/pool-provisioner.yaml" | kubectl apply -f -
