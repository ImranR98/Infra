#!/bin/bash
# DESC: Render templates and start Compose stack
set -euo pipefail
source "$INFRA_ROOT/lib/common.sh"
ensure_envsubst_vars

render_compose_yaml

# Create host volume dirs from compose.yaml (parent dir for files, full path for dirs).
yq -r '.services[] | select(.volumes) | .volumes[] | (.source? // .) | split(":") | .[0]' "$COMPOSE_STATE_DIR/compose.yaml" | grep "^$COMPOSE_STATE_DIR" | while read -r host_path; do
name="$(basename "$host_path")"
if [[ "$name" == *.* ]]; then
    mkdir -p "$(dirname "$host_path")"
    if [ "$UID" -eq 0 ]; then
        chown "$MY_UID:$MY_UID" "$(dirname "$host_path")" 2>/dev/null || :
    fi
else
    mkdir -p "$host_path"
    if [ "$UID" -eq 0 ]; then
        chown "$MY_UID:$MY_UID" "$host_path" 2>/dev/null || :
    fi
fi
done

configure_compose_templates "$TARGET"

docker compose -p "$TARGET" -f "$COMPOSE_STATE_DIR/compose.yaml" up -d --remove-orphans

echo "Installed and started $TARGET Compose stack. Services restart on boot via Docker restart policies."
