#!/bin/bash
# DESC: Build and push the opencode image (Debian trixie + glibc opencode npm
# binary, Node via nvm, core dev tooling, and a Homebrew seed), then re-pin its
# digest in targets/srv0/k3s-apps/templates/opencode.yaml.
# Rebuild after merging a Renovate bump of OPENCODE_VERSION, NODE_VERSION,
# NVM_VERSION, or the Debian base; Renovate also tracks the deployed digest for
# automated PRs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
IMAGE="ghcr.io/imranr98/opencode:latest"
OPENCODE_YAML="$INFRA_ROOT/targets/srv0/k3s-apps/templates/opencode.yaml"

if docker info >/dev/null 2>&1; then
    ENGINE=docker
elif podman info >/dev/null 2>&1; then
    ENGINE=podman
else
    echo "Error: neither Docker nor Podman is usable" >&2
    exit 1
fi

echo "==> Building $IMAGE (linux/amd64) with $ENGINE"
"$ENGINE" build --platform linux/amd64 -t "$IMAGE" "$SCRIPT_DIR"

echo "==> Pushing $IMAGE"
if [ "$ENGINE" = podman ]; then
    # The GHCR login lives in ~/.docker/config.json; podman only reads it when
    # passed explicitly. --digestfile reports the registry manifest digest, not
    # the pre-push local RepoDigest.
    authfile="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
    push_args=()
    [ -f "$authfile" ] && push_args+=(--authfile "$authfile")
    digestfile="$(mktemp)"
    "$ENGINE" push "${push_args[@]}" --digestfile "$digestfile" "$IMAGE"
    digest="$(cat "$digestfile")"
    rm -f "$digestfile"
else
    "$ENGINE" push "$IMAGE"
    digest="$("$ENGINE" inspect --format='{{index .RepoDigests 0}}' "$IMAGE" | sed 's/^[^@]*@//')"
fi
[ -n "$digest" ] || { echo "Error: no pushed digest found for $IMAGE" >&2; exit 1; }

echo "==> Re-pinning $OPENCODE_YAML to $digest"
sed -i -E \
    -e "s|imranrdev/opencode:latest(@sha256:[a-f0-9]+)?|ghcr.io/imranr98/opencode:latest@$digest|" \
    -e "s|ghcr.io/imranr98/opencode:latest(@sha256:[a-f0-9]+)?|ghcr.io/imranr98/opencode:latest@$digest|" \
    "$OPENCODE_YAML"

echo "Pushed $IMAGE@$digest and re-pinned opencode.yaml."
echo "Next: bash scripts/validate.sh srv0 && helm upgrade --install srv0-apps targets/srv0/k3s-apps -n apps --create-namespace -f targets/srv0/k3s-apps/values.yaml -f config/srv0/values.yaml"
