#!/bin/bash
# Stack validator — validates K3s and Compose stacks independently.
# Sourced by common.sh (built-in 'validate' command).  Requires common.sh.
set -euo pipefail

_build_known_vars() {
	local target="$1"; shift
	local extra_vars="$*"
	local known="$extra_vars"
	while IFS= read -r v; do
		[ -z "$v" ] && continue
		known+="
$v"
	done < <(get_template_export_names "$target")
	echo "$known"
}

_yaml_syntax_check() {
	local file="$1" label="$2"
	if yq eval . "$file" >/dev/null 2>&1; then
		return 0
	fi
	echo "ERROR: $label has invalid YAML syntax"
	return 1
}

_check_placeholders() {
	local target="$1"
	local template_file="$ATLAS_ROOT/targets/$target/VARS.template.sh"
	if [ ! -f "$template_file" ]; then
		return
	fi

	local vars_file; vars_file=$(resolve_vars_file "$target")
	if [ -z "$vars_file" ]; then
		return
	fi

	local warns=0
	while IFS= read -r line; do
		local var_name; var_name=$(echo "$line" | grep -oP 'export \K[A-Z_][A-Z_0-9]*' || true)
		[ -z "$var_name" ] && continue
		local template_value; template_value=$(echo "$line" | sed 's/^export [A-Z_][A-Z_0-9]*=//')
		local live_value; live_value=$(grep "^export $var_name=" "$vars_file" 2>/dev/null | sed 's/^export [A-Z_][A-Z_0-9]*=//' || true)
		if [ -n "$live_value" ] && [ "$template_value" = "$live_value" ]; then
			echo "WARN: $var_name still has the template default value. Did you forget to set it?"
			warns=$((warns + 1))
		fi
	done < <(grep '^export ' "$template_file" 2>/dev/null || true)
	return $warns
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
	local target="$1"
	local comp_dir="$ATLAS_ROOT/targets/$target/k3s"
	local errors=0 warnings=0

	local known_vars; known_vars=$(_build_known_vars "$target" "MY_UID
TARGET
COMPOSE_STATE_DIR
COMPOSE_STATE_BACKUP_DIR
LONGHORN_BACKUP_DIR
NS
PV
PVC
VOLUMES")

	_check_placeholders "$target" || warnings=$((warnings + $?))

	for comp_dir in "$comp_dir"/*/; do
		local comp; comp=$(basename "$comp_dir")
		local kfile="$comp_dir/kustomization.yaml"

		if [ ! -f "$kfile" ]; then
			echo "ERROR: $comp missing kustomization.yaml"
			errors=$((errors + 1))
			continue
		fi

		_yaml_syntax_check "$kfile" "$comp/kustomization.yaml" || errors=$((errors + 1))

		while IFS= read -r resource; do
			[ -z "$resource" ] && continue
			if [ ! -f "$comp_dir/$resource" ] && [ ! -d "$comp_dir/$resource" ]; then
				echo "ERROR: $comp/$resource listed in kustomization.yaml but not found"
				errors=$((errors + 1))
			fi
		done < <(yq '.resources[]' "$kfile" 2>/dev/null)

		for yf in "$comp_dir"*.yaml "$comp_dir"*.yml; do
			[ -f "$yf" ] || continue
			local fn; fn=$(basename "$yf")
			[ "$fn" = "kustomization.yaml" ] && continue
			if head -1 "$yf" 2>/dev/null | grep -q "# POST_APPLY"; then continue; fi
			_yaml_syntax_check "$yf" "$comp/$fn" || errors=$((errors + 1))
			if ! grep -qF "$fn" "$kfile"; then
				echo "WARN: $comp/$fn not listed in kustomization.yaml"
				warnings=$((warnings + 1))
			fi
		done

		for overlay_dir in "$comp_dir"/overlays/*/; do
			[ -d "$overlay_dir" ] || continue
			local overlay; overlay=$(basename "$overlay_dir")
			if [ ! -f "$overlay_dir/kustomization.yaml" ]; then
				echo "ERROR: $comp overlay '$overlay' missing kustomization.yaml"
				errors=$((errors + 1))
			fi
		done

		for yf in "$comp_dir"*.yaml "$comp_dir"*.yml; do
			[ -f "$yf" ] || continue
			while IFS= read -r var; do
				[ -z "$var" ] && continue
				if echo "$known_vars" | grep -qx "$var"; then continue; fi
				echo "WARN: $comp/$(basename "$yf") references '\$$var' but it's not defined in VARS template"
				warnings=$((warnings + 1))
			done < <(grep -v '^[[:space:]]*#' "$yf" 2>/dev/null | grep -oP '\$[A-Z_][A-Z_0-9]*|\$\{[A-Z_][A-Z_0-9]*\}' | sed 's/^\$//;s/[{}]//g' | sort -u)
		done
	done

	echo ""
	echo "K3s validation: $errors errors, $warnings warnings"
	return $(( errors > 0 ? 1 : 0 ))
}

_validate_compose() {
	local target="$1"
	local errors=0 warnings=0

	local known_vars; known_vars=$(_build_known_vars "$target" "MY_UID
TARGET
DOCKER_GID
FRPC_USER
COMPOSE_STATE_DIR")

	_check_placeholders "$target" || warnings=$((warnings + $?))

	for f in "$ATLAS_ROOT/targets/$target/compose/compose.yaml" "$ATLAS_ROOT/targets/$target/compose/templates"/*; do
		[ -f "$f" ] || continue
		if [[ "$f" =~ \.(yaml|yml)$ ]]; then
			_yaml_syntax_check "$f" "$(basename "$f")" || { errors=$((errors + 1)); continue; }
		fi
		while IFS= read -r var; do
			[ -z "$var" ] && continue
			if echo "$known_vars" | grep -qx "$var"; then continue; fi
			echo "WARN: $f references '\$$var' but it's not defined in VARS template"
			warnings=$((warnings + 1))
		done < <(grep -hEo '\$[A-Z_][A-Z_0-9]*|\$\{[A-Z_][A-Z_0-9]*\}' "$f" 2>/dev/null | sed 's/^\$//;s/[{}]//g' | sort -u)
	done

	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		if [ -f "$COMPOSE_STATE_DIR/compose.yaml" ]; then
			if ! docker compose -f "$COMPOSE_STATE_DIR/compose.yaml" config --dry-run >/dev/null 2>&1; then
				echo "ERROR: docker compose config validation failed"
				errors=$((errors + 1))
			fi
		else
			echo "NOTE: Docker compose validation skipped (no rendered compose.yaml — run 'compose install' first)"
		fi
	fi

	echo ""
	echo "Compose validation: $errors errors, $warnings warnings"
	return $(( errors > 0 ? 1 : 0 ))
}