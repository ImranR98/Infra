#!/bin/bash
set -euo pipefail

COMP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
: ${VARS_ROOT:="$(cd "$COMP_DIR/../../.." >/dev/null 2>&1 && pwd)"}
: ${TARGET:="sol"}
source "$VARS_ROOT/lib/common.sh"

for crd in middlewares.traefik.io ingressroutes.traefik.io; do
    until kubectl wait --for condition=established "crd/$crd" --timeout=10s 2>/dev/null; do
        sleep 5
    done
done
