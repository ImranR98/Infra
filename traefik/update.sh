#!/bin/bash -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
helm repo update
helm upgrade --namespace production traefik traefik/traefik --values "$HERE"/values.yaml
echo "NOTE: The Helm chart was updated, but there is no guarantee that the chart is in sync with the latest service release."