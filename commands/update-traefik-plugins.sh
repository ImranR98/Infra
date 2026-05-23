#!/bin/bash
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"
update_traefik_plugins "$TARGET"
