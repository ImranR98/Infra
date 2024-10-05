#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HELPERS_PATH"
helm repo update
helm upgrade --install --namespace production loki grafana/loki --values <(cat "$HERE"/files/loki.values.yaml | envsubst)