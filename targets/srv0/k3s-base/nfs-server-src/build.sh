#!/bin/bash
# DESC: Build and push the local nfs-server image (Alpine + nfs-utils +
# entrypoint) that replaces the archived ghcr.io/trexx/docker-nfs-server image,
# then re-pin its digest in targets/srv0/k3s-base/templates/nfs-server.yaml.
# Rebuild after merging a Renovate bump of the Alpine base or after updating
# the pinned nfs-utils version.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
IMAGE="${IMAGE:-imranrdev/nfs-server:v3.22.2-2}"
NFS_YAML="$INFRA_ROOT/targets/srv0/k3s-base/templates/nfs-server.yaml"

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
    # The Docker Hub login lives in ~/.docker/config.json; podman only reads it
    # when passed explicitly. --digestfile reports the registry manifest digest,
    # not the pre-push local RepoDigest.
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

echo "==> Re-pinning $NFS_YAML to $digest"
sed -i -E \
    -e "s|image: ghcr\.io/trexx/docker-nfs-server:[^@[:space:]]+(@sha256:[a-f0-9]+)?|image: ${IMAGE}@${digest}|" \
    -e "s|image: imranrdev/nfs-server:[^@[:space:]]+(@sha256:[a-f0-9]+)?|image: ${IMAGE}@${digest}|" \
    "$NFS_YAML"

echo "Pushed $IMAGE@$digest and re-pinned nfs-server.yaml."
echo "Next: bash scripts/validate.sh srv0 && helm upgrade --install srv0-base targets/srv0/k3s-base -n base --create-namespace -f targets/srv0/k3s-base/values.yaml -f config/srv0/values.yaml"
