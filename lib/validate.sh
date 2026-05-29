#!/bin/bash
set -euo pipefail

_build_known_vars() {
	local target="$1"; shift
	local known="$*"
	while IFS= read -r v; do
		if [ -z "$v" ]; then continue; fi
		known+="
$v"
	done < <(get_template_export_names "$target")
	echo "$known"
}

_check_var_refs() {
	local known_vars="$1" file="$2"
	[ -f "$file" ] || return 0
	local refs; refs=$(grep -oP '\$[A-Z_][A-Z_0-9]*|\$\{[A-Z_][A-Z_0-9]*\}' "$file" 2>/dev/null | sed 's/^\${//; s/^\$//; s/}$//' | sort -u)
	if [ -z "$refs" ]; then return 0; fi
	echo "$refs" | grep -vxFf <(echo "$known_vars") | while read -r v; do
		if [ -z "$v" ]; then continue; fi
		echo "ERROR: $(basename "$file") references '\$$v' but it's not defined in VARS template"
	done
}

validate() {
	local target="${1:-$TARGET}"
	local k3s_ok=true compose_ok=true

	if [ -d "$ATLAS_ROOT/targets/$target/k3s" ]; then
		_validate_k3s "$target" || k3s_ok=false
	fi
	if [ -f "$ATLAS_ROOT/targets/$target/compose/compose.yaml" ]; then
		_validate_compose "$target" || compose_ok=false
	fi

	echo ""
	echo "K3s:     $( $k3s_ok && echo "OK" || echo "issues found" )"
	echo "Compose: $( $compose_ok && echo "OK" || echo "issues found" )"
}

_validate_k3s() {
	local target="$1" comp_dir="$ATLAS_ROOT/targets/$target/k3s" errors=0

	local known_vars; known_vars=$(_build_known_vars "$target" "MY_UID
TARGET
COMPOSE_STATE_DIR
COMPOSE_STATE_BACKUP_DIR
LONGHORN_BACKUP_DIR
NS
PV
PVC
VOLUMES")

	for comp_dir in "$comp_dir"/*/; do
		local comp; comp=$(basename "$comp_dir")
		local kfile="$comp_dir/kustomization.yaml"

		[ -f "$kfile" ] || { echo "ERROR: $comp missing kustomization.yaml"; errors=$((errors + 1)); continue; }

		if command -v kubectl >/dev/null 2>&1; then
			kubectl kustomize "$comp_dir" >/dev/null || { echo "ERROR: $comp kustomize build failed"; errors=$((errors + 1)); }
		fi

		local yaml_files=()
		for yf in "$comp_dir"/*.yaml "$comp_dir"/*.yml; do if [ -f "$yf" ]; then yaml_files+=("$yf"); fi; done
		for yf in "${yaml_files[@]}"; do
			local ref_errors; ref_errors=$(_check_var_refs "$known_vars" "$yf")
			if [ -n "$ref_errors" ]; then
				echo "$ref_errors"
				errors=$((errors + $(echo "$ref_errors" | wc -l)))
			fi
		done
	done

	echo ""
	echo "K3s validation: $errors errors"
	return $(( errors > 0 ? 1 : 0 ))
}

_validate_compose() {
	local target="$1" errors=0

	for f in "$ATLAS_ROOT/targets/$target/compose/compose.yaml" "$ATLAS_ROOT/targets/$target/compose/templates"/*; do
		[ -f "$f" ] || continue
		if [[ "$f" =~ \.(yaml|yml)$ ]]; then
			if ! yq eval '.' "$f" >/dev/null 2>&1; then
				echo "ERROR: $(basename "$f") has invalid YAML syntax"
				errors=$((errors + 1))
			fi
		fi
	done

	local known_vars; known_vars=$(_build_known_vars "$target" "MY_UID
TARGET
DOCKER_GID
FRPC_USER
COMPOSE_STATE_DIR")

	local compose_files=("$ATLAS_ROOT/targets/$target/compose/compose.yaml")
	for f in "$ATLAS_ROOT/targets/$target/compose/templates"/*; do if [ -f "$f" ]; then compose_files+=("$f"); fi; done
	for f in "${compose_files[@]}"; do
		local ref_errors; ref_errors=$(_check_var_refs "$known_vars" "$f")
		if [ -n "$ref_errors" ]; then
			echo "$ref_errors"
			errors=$((errors + $(echo "$ref_errors" | wc -l)))
		fi
	done

	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		if [ -f "$COMPOSE_STATE_DIR/compose.yaml" ]; then
			docker compose -f "$COMPOSE_STATE_DIR/compose.yaml" config --dry-run >/dev/null || { echo "ERROR: docker compose config validation failed"; errors=$((errors + 1)); }
		fi
	fi

	echo ""
	echo "Compose validation: $errors errors"
	return $(( errors > 0 ? 1 : 0 ))
}