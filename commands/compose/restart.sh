#!/bin/bash
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"

SVC="${1:-}"
if [ -z "$SVC" ]; then
	echo "No service specified. Nothing will be restarted." >&2
	exit 1
fi

configure_compose_templates "$TARGET"
render_compose_yaml
docker compose --env-file "$COMPOSE_STATE_DIR/.env" -p "$TARGET" -f "$COMPOSE_STATE_DIR/compose.yaml" down "$SVC" || :
docker compose --env-file "$COMPOSE_STATE_DIR/.env" -p "$TARGET" -f "$COMPOSE_STATE_DIR/compose.yaml" up -d "$SVC"
