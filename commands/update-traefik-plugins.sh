#!/bin/bash
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"
source "$ATLAS_ROOT/lib/update-traefik-plugins.sh"
update_traefik_plugins "$TARGET"
