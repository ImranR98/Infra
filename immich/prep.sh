#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
helm repo add immich https://immich-app.github.io/immich-charts
mkdir -p "$STATE_DIR"/immich/postgres
mkdir -p "$STATE_DIR"/immich/redis
mkdir -p "$STATE_DIR"/immich/server