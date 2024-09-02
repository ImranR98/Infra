#!/bin/bash -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
kubectl apply -f "$HERE"/pv.yaml
helm repo add immich https://immich-app.github.io/immich-charts
mkdir -p "$HERE"/../state/immich/postgres
mkdir -p "$HERE"/../state/immich/redis