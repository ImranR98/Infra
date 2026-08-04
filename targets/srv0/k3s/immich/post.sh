#!/bin/bash
# Patch machine-learning deployment with GPU resource when GPU nodes are available.
# The Immich Helm chart strips custom resource types; we patch post-render.
set -euo pipefail
if [ "${GPU_NODES_AVAILABLE:-false}" != "true" ]; then
    exit 0
fi

echo "GPU nodes detected — adding amd.com/gpu to immich-machine-learning..."
sleep 5  # let Helm finish reconciling
kubectl patch deployment -n apps immich-machine-learning --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/resources/limits/amd.com~1gpu","value":"1"},{"op":"add","path":"/spec/template/spec/containers/0/resources/requests/amd.com~1gpu","value":"1"}]' 2>/dev/null || true
kubectl rollout restart deployment/immich-machine-learning -n apps
