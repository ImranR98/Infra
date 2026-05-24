#!/bin/bash
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"

ENVSUBST_VARS="$(get_envsubst_vars)"

echo "=== Create Required Directories ==="
tmpfile="$(mktemp)"
trap 'rm -f "$tmpfile"' EXIT INT TERM
envsubst "$ENVSUBST_VARS" < "$ATLAS_ROOT/targets/$TARGET/compose/compose.yaml" > "$tmpfile"
while IFS=: read -r host_path _; do
	name="$(basename "$host_path")"
	if [[ "$name" =~ \.[a-zA-Z0-9]{1,5}$ ]]; then
		mkdir -p "$(dirname "$host_path")"
		[ "$UID" -eq 0 ] && chown "$MY_UID:$MY_UID" "$(dirname "$host_path")" 2>/dev/null || :
	else
		mkdir -p "$host_path"
		[ "$UID" -eq 0 ] && chown "$MY_UID:$MY_UID" "$host_path" 2>/dev/null || :
	fi
done < <(awk -v dir="$COMPOSE_STATE_DIR" 'index($0, dir"/") && /^[[:space:]]*-/ { sub(/^[[:space:]]*-[[:space:]]*"?/, ""); sub(/[":].*/, ""); print }' "$tmpfile")
echo "Done."

generate_compose_configs "$TARGET"

echo "=== Generate Docker Compose file ==="
cp "$tmpfile" "$COMPOSE_STATE_DIR/compose.yaml"
rm -f "$tmpfile"
echo "Done."

echo "=== Install and start the $TARGET service ==="
cat > "$COMPOSE_STATE_DIR/$TARGET.service" << EOF
[Unit]
Description=$TARGET start
StartLimitIntervalSec=0

[Service]
User=$UID
Type=simple
ExecStart=/usr/bin/docker compose -p $TARGET -f $COMPOSE_STATE_DIR/compose.yaml up
ExecStop=/usr/bin/docker compose -p $TARGET -f $COMPOSE_STATE_DIR/compose.yaml down
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
SU=$(get_sudo_cmd)
$SU mv "$COMPOSE_STATE_DIR/$TARGET.service" "/etc/systemd/system/$TARGET.service"
command -v chcon &>/dev/null && $SU chcon -t systemd_unit_file_t /etc/systemd/system/$TARGET.service 2>/dev/null || true
$SU systemctl daemon-reload && $SU systemctl enable $TARGET.service
$SU systemctl restart $TARGET.service 2>/dev/null || $SU systemctl start $TARGET.service
echo "Done."

echo "=== Finished ==="
echo "Note: Some services may need manual setup in their respective GUIs."
echo ""
