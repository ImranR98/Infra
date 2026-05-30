#!/bin/bash
set -euo pipefail

render_compose_yaml() {
	ensure_envsubst_vars
	mkdir -p "$COMPOSE_STATE_DIR"
	envsubst "$ENVSUBST_VARS" < "$ATLAS_ROOT/targets/$TARGET/compose/compose.yaml" > "$COMPOSE_STATE_DIR/compose.yaml"
}

configure_compose_templates() {
	local target="$1"
	ensure_envsubst_vars
	local template_dir="$ATLAS_ROOT/targets/$target/compose/templates"
	[ -d "$template_dir" ] || return

	while IFS= read -r -d '' src; do
		local rel="${src#$template_dir/}"
		local dst="$COMPOSE_STATE_DIR/$rel"
		dst="${dst%.secret}"
		dst="${dst%.plain}"
		mkdir -p "$(dirname "$dst")"

		case "$rel" in
			*.plain) cp "$src" "$dst" ;;
			*.secret)
				envsubst "$ENVSUBST_VARS" < "$src" > "$dst"
				chmod 600 "$dst" ;;
			authelia/*)
				if [ ! -f "$dst" ]; then
					sed '/# IGNORE INITIALLY$/ s/^/# /' "$src" | envsubst "$ENVSUBST_VARS" > "$dst"
				else
					envsubst "$ENVSUBST_VARS" < "$src" > "$dst"
				fi
				printf '%s\n' "$AUTHELIA_USERS_DATABASE" > "$COMPOSE_STATE_DIR/authelia/config/users_database.yml" ;;
			traefik/*)
				[ -f "$COMPOSE_STATE_DIR/traefik/acme.json" ] || { echo '{}' > "$COMPOSE_STATE_DIR/traefik/acme.json"; chmod 600 "$COMPOSE_STATE_DIR/traefik/acme.json"; }
				envsubst "$ENVSUBST_VARS" < "$src" > "$dst" ;;
			*) envsubst "$ENVSUBST_VARS" < "$src" > "$dst" ;;
		esac
	done < <(find "$template_dir" -type f -print0)
}
