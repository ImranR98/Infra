#!/bin/bash
# Compose config generation for Atlas.

render_compose_yaml() {
	if [ -z "${ENVSUBST_VARS:-}" ]; then
		ENVSUBST_VARS="$(get_envsubst_vars)"
	fi
	mkdir -p "$COMPOSE_STATE_DIR"
	envsubst "$ENVSUBST_VARS" < "$ATLAS_ROOT/targets/$TARGET/compose/compose.yaml" > "$COMPOSE_STATE_DIR/compose.yaml"
}

generate_compose_configs() {
	local target="$1"

	if [ -z "${ENVSUBST_VARS:-}" ]; then
		ENVSUBST_VARS="$(get_envsubst_vars)"
	fi
	echo "=== Re/generate various state files ==="

	local _templates=()

	[ -f "$ATLAS_ROOT/targets/$target/compose/templates/authelia.config.yaml" ] && \
		_templates+=("authelia|$ATLAS_ROOT/targets/$target/compose/templates/authelia.config.yaml|$COMPOSE_STATE_DIR/authelia/config/configuration.yml")

	[ -f "$ATLAS_ROOT/targets/$target/compose/templates/traefik.dynamic-configuration.yaml" ] && \
		_templates+=("traefik|$ATLAS_ROOT/targets/$target/compose/templates/traefik.dynamic-configuration.yaml|$COMPOSE_STATE_DIR/traefik/dynamic-configuration.yaml")

	[ -f "$ATLAS_ROOT/targets/$target/compose/templates/plausible.clickhouse-config.xml" ] && \
		_templates+=("plausible|$ATLAS_ROOT/targets/$target/compose/templates/plausible.clickhouse-config.xml|$COMPOSE_STATE_DIR/plausible/config/clickhouse-config.xml")

	[ -f "$ATLAS_ROOT/targets/$target/compose/templates/frpc.toml" ] && \
		_templates+=("frpc|$ATLAS_ROOT/targets/$target/compose/templates/frpc.toml|$COMPOSE_STATE_DIR/frpc/frpc.toml")

	[ -f "$ATLAS_ROOT/targets/$target/compose/templates/frps-tokens.txt" ] && \
		_templates+=("frps|$ATLAS_ROOT/targets/$target/compose/templates/frps-tokens.txt|$COMPOSE_STATE_DIR/frps/tokens.txt")

	[ -f "$ATLAS_ROOT/targets/$target/compose/templates/logtfy.config.json" ] && \
		_templates+=("logtfy|$ATLAS_ROOT/targets/$target/compose/templates/logtfy.config.json|$COMPOSE_STATE_DIR/logtfy/config.json")

	for entry in "${_templates[@]}"; do
		local _type="${entry%%|*}"; local _rest="${entry#*|}"
		local _src="${_rest%%|*}"; local _dst="${_rest#*|}"
		local _dstdir; _dstdir="$(dirname "$_dst")"

		case "$_type" in
			authelia)
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
				;;
			traefik)
				mkdir -p "$_dstdir"
				if [ ! -f "$COMPOSE_STATE_DIR/traefik/acme.json" ]; then
					echo '{}' >"$COMPOSE_STATE_DIR/traefik/acme.json"
					echo "Created an empty \"acme.json\"."
				fi
				chmod 600 "$COMPOSE_STATE_DIR/traefik/acme.json"
				envsubst "$ENVSUBST_VARS" < "$_src" > "$_dst"
				;;
			plausible)
				mkdir -p "$_dstdir"
				cp "$_src" "$_dst"
				;;
			frpc)
				mkdir -p "$_dstdir"
				envsubst "$ENVSUBST_VARS" < "$_src" > "$_dst"
				chmod 600 "$_dst"
				;;
			frps)
				mkdir -p "$_dstdir"
				envsubst "$ENVSUBST_VARS" < "$_src" > "$_dst"
				chmod 600 "$_dst"
				;;
			logtfy)
				echo "=== Generate Logtfy config ==="
				mkdir -p "$_dstdir"
				envsubst "$ENVSUBST_VARS" < "$_src" > "$_dst"
				echo "Done."
				;;
		esac
	done

	if [ ! -f "$ATLAS_ROOT/targets/$target/compose/templates/logtfy.config.json" ]; then
		echo "No logtfy config template found. Skipping."
	fi
}
