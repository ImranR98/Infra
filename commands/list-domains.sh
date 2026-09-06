#!/bin/bash
# DESC: Show domains used by this target
set -euo pipefail
source "$INFRA_ROOT/lib/common.sh"
list_domains "${TARGET:?TARGET not set}" || true
