#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/common.sh"
source_env

for crd in middlewares.traefik.io ingressroutes.traefik.io; do
    until kubectl wait --for condition=established "crd/$crd" --timeout=10s 2>/dev/null; do
        sleep 5
    done
done
