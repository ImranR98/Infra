#!/bin/bash
set -euo pipefail
# Compose config generation for Atlas.

render_compose_yaml() {
	ensure_envsubst_vars
	mkdir -p "$COMPOSE_STATE_DIR"
	envsubst "$ENVSUBST_VARS" < "$ATLAS_ROOT/targets/$TARGET/compose/compose.yaml" > "$COMPOSE_STATE_DIR/compose.yaml"
}

_generate_authelia_config() {
	local _src="$1" _dst="$2" _dstdir; _dstdir="$(dirname "$_dst")"
	mkdir -p "$_dstdir"
	if [ -f "$_dst" ]; then
		PROTECT_INIT_ROUTES=${PROTECT_INIT_ROUTES:-false}
	else
		PROTECT_INIT_ROUTES=${PROTECT_INIT_ROUTES:-true}
	fi
	echo "PROTECT_INIT_ROUTES=$PROTECT_INIT_ROUTES"
	if [ "$PROTECT_INIT_ROUTES" = true ]; then
		sed '/# IGNORE INITIALLY$/ s/^/# /' "$_src" | envsubst "$ENVSUBST_VARS" >"$_dst"
		echo "Note: the generated Authelia config does not include lines that end with \"# IGNORE INITIALLY\"."
	else
		envsubst "$ENVSUBST_VARS" < "$_src" >"$_dst"
	fi
	printf '%s\n' "$AUTHELIA_USERS_DATABASE" >"$COMPOSE_STATE_DIR/authelia/config/users_database.yml"
}

_generate_traefik_config() {
	local _src="$1" _dst="$2" _dstdir; _dstdir="$(dirname "$_dst")"
	mkdir -p "$_dstdir"
	if [ ! -f "$COMPOSE_STATE_DIR/traefik/acme.json" ]; then
		echo '{}' >"$COMPOSE_STATE_DIR/traefik/acme.json"
		echo "Created an empty \"acme.json\"."
	fi
	chmod 600 "$COMPOSE_STATE_DIR/traefik/acme.json"
	envsubst "$ENVSUBST_VARS" < "$_src" > "$_dst"
}

_generate_plain_config() {
	local _src="$1" _dst="$2" _dstdir; _dstdir="$(dirname "$_dst")"
	mkdir -p "$_dstdir"
	cp "$_src" "$_dst"
}

_generate_secret_config() {
	local _src="$1" _dst="$2" _dstdir; _dstdir="$(dirname "$_dst")"
	mkdir -p "$_dstdir"
	envsubst "$ENVSUBST_VARS" < "$_src" > "$_dst"
	chmod 600 "$_dst"
}

_generate_envsubst_config() {
	local _src="$1" _dst="$2" _dstdir; _dstdir="$(dirname "$_dst")"
	mkdir -p "$_dstdir"
	envsubst "$ENVSUBST_VARS" < "$_src" > "$_dst"
}

declare -A _CONFIG_HANDLERS=(
	[authelia.config.yaml]=_generate_authelia_config
	[traefik.dynamic-configuration.yaml]=_generate_traefik_config
	[plausible.clickhouse-config.xml]=_generate_plain_config
	[frpc.toml]=_generate_secret_config
	[frps-tokens.txt]=_generate_secret_config
	[logtfy.config.json]=_generate_envsubst_config
)

generate_compose_configs() {
	local target="$1"
	ensure_envsubst_vars
	echo "=== Re/generate various state files ==="

	local template_dir="$ATLAS_ROOT/targets/$target/compose/templates"
	if [ ! -d "$template_dir" ]; then
		echo "No templates directory found. Skipping."
		return
	fi

	for f in "$template_dir"/*; do
		[ -f "$f" ] || continue
		local fn; fn=$(basename "$f")
		local handler="${_CONFIG_HANDLERS[$fn]:-}"
		if [ -z "$handler" ]; then
			echo "Note: no handler for template '$fn'. Skipping."
			continue
		fi
		local _dst="${f##*/}"
		_dst="${_dst%.config.yaml}"
		_dst="${_dst%.dynamic-configuration.yaml}"
		_dst="${_dst%.clickhouse-config.xml}"
		_dst="${_dst%.toml}"
		_dst="${_dst%.txt}"
		_dst="${_dst%.json}"
		case "$fn" in
			authelia.config.yaml) _dst="$COMPOSE_STATE_DIR/authelia/config/configuration.yml" ;;
			traefik.dynamic-configuration.yaml) _dst="$COMPOSE_STATE_DIR/traefik/dynamic-configuration.yaml" ;;
			plausible.clickhouse-config.xml) _dst="$COMPOSE_STATE_DIR/plausible/config/clickhouse-config.xml" ;;
			frpc.toml) _dst="$COMPOSE_STATE_DIR/frpc/frpc.toml" ;;
			frps-tokens.txt) _dst="$COMPOSE_STATE_DIR/frps/tokens.txt" ;;
			logtfy.config.json) _dst="$COMPOSE_STATE_DIR/logtfy/config.json" ;;
			*) _dst="$COMPOSE_STATE_DIR/${_dst}.${fn##*.}" ;;
		esac
		"$handler" "$f" "$_dst"
	done
}
