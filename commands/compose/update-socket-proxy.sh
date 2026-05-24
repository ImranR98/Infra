#!/bin/bash
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"

echo "=== Pull Latest 'wollomatic/socket-proxy:1' and Restart $TARGET if Needed ==="
OLDSPHASH="$(docker images wollomatic/socket-proxy:1 --format '{{.ID}}')"
docker pull wollomatic/socket-proxy:1
NEWSPHASH="$(docker images wollomatic/socket-proxy:1 --format '{{.ID}}')"
if [ "$OLDSPHASH" != "$NEWSPHASH" ]; then
	read -p "New image pulled. Press enter to restart $TARGET..." NOTHING || true
	$(get_sudo_cmd) systemctl restart "$TARGET"
else
	echo "wollomatic/socket-proxy:1 is already the latest (only the :1 tag is tracked)."
fi
