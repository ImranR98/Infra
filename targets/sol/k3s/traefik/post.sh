#!/bin/bash
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"
source "$ATLAS_ROOT/lib/wait-for-crd.sh"

wait_for_crds 150 middlewares.traefik.io ingressroutes.traefik.io
