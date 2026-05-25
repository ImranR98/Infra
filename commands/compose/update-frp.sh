#!/bin/bash
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"

TARGET_SERVER="$2"
if [ -z "$TARGET_SERVER" ] || [ ! -f "$ATLAS_ROOT/targets/$TARGET_SERVER/compose/compose.yaml" ]; then
	echo "FRPS target name not specified!" >&2
	exit 1
fi

frpc_compose_file="$ATLAS_ROOT/targets/$TARGET/compose/compose.yaml"
if [ ! -f "$frpc_compose_file" ]; then
	echo "No compose file found for target '$TARGET'." >&2; exit 1
fi
current_ver="$(sed -n 's/.*image: fatedier\/frpc:v\([^"]*\).*/\1/p' "$frpc_compose_file")"
if [ -z "$current_ver" ]; then
	echo "No fatedier/frpc image found in $frpc_compose_file. Nothing to update." >&2; exit 0
fi
echo "Current FRPC version: v$current_ver"

latest_tag="$(curl -s https://api.github.com/repos/fatedier/frp/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')"
latest_ver="${latest_tag#v}"
echo "Latest FRP version:  v$latest_ver"

if [ "$current_ver" = "$latest_ver" ]; then
	echo "FRPC is already at the latest version."; exit 0
fi

echo "Updating $TARGET.compose.yaml..."
sed -i "s|image: fatedier/frpc:v$current_ver|image: fatedier/frpc:v$latest_ver|" "$frpc_compose_file"
echo "Updating lens.compose.yaml..."
sed -i "s|image: imranrdev/frps-with-multiuser:latest|image: imranrdev/frps-with-multiuser:v$latest_ver|" "$ATLAS_ROOT/targets/$TARGET_SERVER/compose/compose.yaml"

echo "=== Build frps-with-multiuser:v$latest_ver ==="
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT INT TERM
git clone https://github.com/ImranR98/frps-with-multiuser-docker.git "$TMPDIR"
cd "$TMPDIR"
docker build --no-cache . --network host -t "imranrdev/frps-with-multiuser:v$latest_ver"
docker push "imranrdev/frps-with-multiuser:v$latest_ver"
echo "=== Done ==="

echo ""
echo "FRPC updated from v$current_ver to v$latest_ver."
echo "Compose files updated and image pushed to Docker Hub."
echo ""
echo "Next steps:"
echo "  1. Commit and push the changes."
echo "  2. On $TARGET_SERVER, pull the repo and restart the frps-with-multiuser container."
echo "  3. On $TARGET, restart the frpc container."
echo ""
