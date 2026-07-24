#!/bin/bash
set -euo pipefail

source "$INFRA_ROOT/lib/common.sh"

echo "Waiting for Longhorn CRDs..."
wait_for_crds 300 \
  volumes.longhorn.io \
  engines.longhorn.io \
  replicas.longhorn.io \
  nodes.longhorn.io \
  settings.longhorn.io \
  instancemanagers.longhorn.io

echo "Waiting for Longhorn manager..."
retry 60 5 "kubectl -n longhorn-system wait --for=condition=Ready pod -l app=longhorn-manager --timeout=10s >/dev/null 2>&1"

echo "Waiting for Longhorn UI..."
retry 60 5 "kubectl -n longhorn-system wait --for=condition=Ready pod -l app=longhorn-ui --timeout=10s >/dev/null 2>&1"

echo "Waiting for Longhorn CSI driver..."
retry 60 5 "kubectl -n longhorn-system wait --for=condition=Ready pod -l app=longhorn-csi-plugin --timeout=10s >/dev/null 2>&1"

echo "Waiting for longhorn StorageClass..."
retry 30 5 "kubectl get sc longhorn >/dev/null 2>&1"

echo "Longhorn is ready."
