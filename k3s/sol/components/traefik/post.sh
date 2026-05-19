#!/bin/bash
set -euo pipefail

COMP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
export VARS_ROOT="$(cd "$COMP_DIR/../../../.." >/dev/null 2>&1 && pwd)"
export TARGET="$(basename "$(cd "$COMP_DIR/../.." >/dev/null 2>&1 && pwd)")"
source "$VARS_ROOT/lib/vars.sh"
source_env

for crd in middlewares.traefik.io ingressroutes.traefik.io; do
    until kubectl wait --for condition=established "crd/$crd" --timeout=10s 2>/dev/null; do
        sleep 5
    done
done
