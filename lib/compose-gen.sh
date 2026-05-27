#!/bin/bash
set -euo pipefail
# Compose config generation for Atlas.

render_compose_yaml() {
	ensure_envsubst_vars
	mkdir -p "$COMPOSE_STATE_DIR"
	envsubst "$ENVSUBST_VARS" < "$ATLAS_ROOT/targets/$TARGET/compose/compose.yaml" > "$COMPOSE_STATE_DIR/compose.yaml"
	_write_compose_env
}

_write_compose_env() {
	local env_file="$COMPOSE_STATE_DIR/.env"
	{
		printf 'COMPOSE_STATE_DIR=%s\n' "$COMPOSE_STATE_DIR"
		printf 'TARGET=%s\n' "$TARGET"
		printf 'MY_UID=%s\n' "$MY_UID"
		printf 'DOCKER_GID=%s\n' "${DOCKER_GID:-}"
		printf 'FRPC_USER=%s\n' "${FRPC_USER:-}"
		local vars_file; vars_file=$(resolve_vars_file "$TARGET")
		if [ -n "$vars_file" ]; then
			grep -oP '^export \K[A-Z_][A-Z_0-9]*' "$vars_file" | while IFS= read -r vname; do
				printf '%s=%s\n' "$vname" "${!vname:-}"
			done
		fi
	} > "$env_file"
}

_generate_config() {
	local _mode="$1" _src="$2" _dst="$3"
	mkdir -p "$(dirname "$_dst")"
	case "$_mode" in
		plain) cp "$_src" "$_dst" ;;
		secret|normal)
			envsubst "$ENVSUBST_VARS" < "$_src" > "$_dst"
			if [ "$_mode" = "secret" ]; then
				chmod 600 "$_dst"
			fi
			;;
		authelia)
			if [ -f "$_dst" ]; then
				PROTECT_INIT_ROUTES=${PROTECT_INIT_ROUTES:-false}
			else
				PROTECT_INIT_ROUTES=${PROTECT_INIT_ROUTES:-true}
			fi
			if [ "$PROTECT_INIT_ROUTES" = true ]; then
				sed '/# IGNORE INITIALLY$/ s/^/# /' "$_src" | envsubst "$ENVSUBST_VARS" >"$_dst"
			else
				envsubst "$ENVSUBST_VARS" < "$_src" >"$_dst"
			fi
			printf '%s\n' "$AUTHELIA_USERS_DATABASE" >"$COMPOSE_STATE_DIR/authelia/config/users_database.yml"
			;;
		traefik)
			[ -f "$COMPOSE_STATE_DIR/traefik/acme.json" ] || echo '{}' >"$COMPOSE_STATE_DIR/traefik/acme.json"
			chmod 600 "$COMPOSE_STATE_DIR/traefik/acme.json"
			envsubst "$ENVSUBST_VARS" < "$_src" > "$_dst"
			;;
	esac
}

configure_compose_templates() {
	local target="$1"
	ensure_envsubst_vars
	local template_dir="$ATLAS_ROOT/targets/$target/compose/templates"
	[ -d "$template_dir" ] || return
	local map_file="$template_dir/map"
	[ -f "$map_file" ] || return
	while IFS=: read -r mode src dest; do
		if [[ "$mode" =~ ^# ]]; then continue; fi
		if [ -z "$mode" ]; then continue; fi
		_generate_config "$mode" "$template_dir/$src" "$COMPOSE_STATE_DIR/$dest"
	done < "$map_file"
}