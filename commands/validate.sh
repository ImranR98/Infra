#!/bin/bash
# DESC: Check configs for errors
set -euo pipefail
source "$INFRA_ROOT/lib/common.sh"
validate "${TARGET:?TARGET not set}"
