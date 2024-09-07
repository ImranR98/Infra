#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
helm repo update
helm upgrade --namespace production traefik traefik/traefik --values <(cat "$HERE"/values.yaml | envsubst)
kubectl -n production rollout restart deployment traefik
echo "NOTE: The Helm chart was updated, but there is no guarantee that the chart is in sync with the latest service release."