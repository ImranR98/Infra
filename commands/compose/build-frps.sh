#!/bin/bash
# DESC: Build and push the frps-with-multiuser Docker image
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"

TARGET_SERVER="$2"
if [ -z "$TARGET_SERVER" ] || [ ! -f "$ATLAS_ROOT/targets/$TARGET_SERVER/compose/compose.yaml" ]; then
	echo "FRPS target name must be specified!" >&2
	echo "Usage: $0 <target> compose build-frps <frps-target>" >&2
	exit 1
fi

_frpc_file="$ATLAS_ROOT/targets/$TARGET/compose/compose.yaml"
_frps_file="$ATLAS_ROOT/targets/$TARGET_SERVER/compose/compose.yaml"

_ver="$(sed -n 's/.*image: fatedier\/frpc:v\([^" ]*\).*/\1/p' "$_frpc_file" | head -1)"
if [ -z "$_ver" ]; then
	echo "No fatedier/frpc image found in target $TARGET." >&2
	exit 1
fi

echo "FRP version from $TARGET: v$_ver"

echo "=== Build frps-with-multiuser:v$_ver ==="
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT INT TERM
git clone https://github.com/ImranR98/frps-with-multiuser-docker.git "$TMPDIR"
cd "$TMPDIR"
docker build --no-cache . --network host -t "imranrdev/frps-with-multiuser:v$_ver"
docker push "imranrdev/frps-with-multiuser:v$_ver"
echo "=== Done ==="

echo ""
echo "Updating $_frps_file to imranrdev/frps-with-multiuser:v$_ver..."
sed -i "s|imranrdev/frps-with-multiuser:v[^\"]*|imranrdev/frps-with-multiuser:v$_ver|" "$_frps_file"
echo "Updated $TARGET_SERVER compose. Commit and push the changes."
