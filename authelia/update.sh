#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
helm repo update
helm upgrade authelia authelia/authelia --values <(cat "$HERE"/values.yaml | envsubst) --namespace production
kubectl apply -f <(cat "$HERE"/files/authelia-users.yaml | envsubst)
echo "NOTE: The Helm chart was updated, but there is no guarantee that the chart is in sync with the latest service release."