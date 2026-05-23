#!/bin/bash
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"

SVC="${1:-}"
if [ -z "$SVC" ]; then
	echo "No service specified. Nothing will be restarted."
	exit 0
fi

ENVSUBST_VARS="$(get_envsubst_vars)"
generate_compose_configs "$TARGET"
envsubst "$ENVSUBST_VARS" < "$ATLAS_ROOT/targets/$TARGET/compose/compose.yaml" > "$COMPOSE_STATE_DIR/compose.yaml"
docker compose -p "$TARGET" -f "$COMPOSE_STATE_DIR/compose.yaml" down "$SVC" || :
docker compose -p "$TARGET" -f "$COMPOSE_STATE_DIR/compose.yaml" up -d "$SVC"
