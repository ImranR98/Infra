#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
bash "$HERE"/install.sh
kubectl -n production rollout restart deployment immich-server immich-machine-learning
kubectl -n production rollout restart statefulset immich-postgresql immich-redis-master