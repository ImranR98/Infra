#!/bin/bash
# DESC: Build and push the opencode image (FROM the upstream ghcr.io image),
# then re-pin its digest in targets/srv0/k3s-apps/templates/opencode.yaml.
# Rebuild after merging a Renovate bump of the FROM image; Renovate tracks the
# digest for automated PRs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
IMAGE="imranrdev/opencode:latest"
OPENCODE_YAML="$INFRA_ROOT/targets/srv0/k3s-apps/templates/opencode.yaml"

command -v docker >/dev/null 2>&1 || { echo "Error: docker not found" >&2; exit 1; }

echo "==> Building $IMAGE (linux/amd64)"
docker build --platform linux/amd64 -t "$IMAGE" "$SCRIPT_DIR"

echo "==> Pushing $IMAGE"
docker push "$IMAGE"

digest="$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE" | sed 's/^[^@]*@//')"
[ -n "$digest" ] || { echo "Error: no pushed digest found for $IMAGE" >&2; exit 1; }

echo "==> Re-pinning $OPENCODE_YAML to $digest"
sed -i "s|imranrdev/opencode:latest\(@sha256:[a-f0-9]*\)\?|imranrdev/opencode:latest@$digest|" "$OPENCODE_YAML"

echo "Pushed $IMAGE@$digest and re-pinned opencode.yaml."
echo "Next: bash scripts/validate.sh srv0 && helm upgrade --install srv0-apps targets/srv0/k3s-apps -n apps --create-namespace -f targets/srv0/k3s-apps/values.yaml -f config/srv0/values.yaml"
