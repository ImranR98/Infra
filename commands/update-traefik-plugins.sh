#!/bin/bash
set -euo pipefail
source "$VARS_ROOT/lib/common.sh"
update_traefik_plugins "$TARGET"
