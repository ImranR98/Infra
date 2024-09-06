#!/bin/bash -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
helm repo update
helm upgrade --namespace production immich immich/immich -f "$HERE"/values.yaml
kubectl -n production rollout restart deployment immich-server immich-machine-learning
kubectl -n production rollout restart statefulset immich-postgresql immich-redis-master