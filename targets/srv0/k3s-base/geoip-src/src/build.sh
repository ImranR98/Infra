#!/bin/bash
# DESC: Build and push the geoip-service image, then re-pin its digest in the
# k8s chart (targets/srv0/k3s-base/templates/geoip.yaml). Run after merging a
# go.mod change; Renovate tracks the digest for automated PRs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
IMAGE="imranrdev/geoip-service:latest"
GEOIP_YAML="$INFRA_ROOT/targets/srv0/k3s-base/templates/geoip.yaml"

command -v docker >/dev/null 2>&1 || { echo "Error: docker not found" >&2; exit 1; }

echo "==> Building $IMAGE (linux/amd64)"
docker build --platform linux/amd64 -t "$IMAGE" "$SCRIPT_DIR"

echo "==> Pushing $IMAGE"
docker push "$IMAGE"

digest="$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE" | sed 's/^[^@]*@//')"
[ -n "$digest" ] || { echo "Error: no pushed digest found for $IMAGE" >&2; exit 1; }

echo "==> Re-pinning $GEOIP_YAML to $digest"
sed -i "s|imranrdev/geoip-service:latest@sha256:[a-f0-9]*|imranrdev/geoip-service:latest@$digest|" "$GEOIP_YAML"

echo "Pushed $IMAGE@$digest and re-pinned geoip.yaml."
echo "Next: bash scripts/validate.sh srv0 && helm upgrade --install srv0-base targets/srv0/k3s-base -n base --create-namespace -f targets/srv0/k3s-base/values.yaml -f config/srv0/values.yaml"
