#!/bin/bash
# DESC: Render templates, install systemd service, start Compose stack
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"
ensure_envsubst_vars

render_compose_yaml
yq -r '.services[].volumes[] | (select(tag == "!!str") | split(":") | .[0]) // (select(tag == "!!map") | .source | split(":") | .[0])' "$COMPOSE_STATE_DIR/compose.yaml" | grep "^$COMPOSE_STATE_DIR" | while read -r host_path; do
	name="$(basename "$host_path")"
	if [[ "$name" =~ \.[a-zA-Z0-9]{1,5}$ ]]; then
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

echo "Installed and started $TARGET service."
