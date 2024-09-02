#!/bin/bash -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
helm repo add immich https://immich-app.github.io/immich-charts
mkdir -p "$HERE"/../state/immich/postgres
mkdir -p "$HERE"/../state/immich/redis