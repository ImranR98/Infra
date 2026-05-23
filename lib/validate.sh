#!/bin/bash
# Stack validator — validates K3s and Compose stacks independently.
# Sourced by commands/validate.sh.  Requires common.sh.

# ---- Validate (both stacks) ----

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

	# Gather required vars from VARS template
	# NS, PV, PVC, VOLUMES are shell-local variables used in inline
	# command: blocks — not envsubst vars.  Exempted to avoid false warnings.
	local known_vars="MY_UID
TARGET
COMPOSE_STATE_DIR
COMPOSE_STATE_BACKUP_DIR
LONGHORN_BACKUP_DIR
NS
PV
PVC
VOLUMES"
	local template_file="$ATLAS_ROOT/targets/$target/VARS.template.sh"
	if [ -f "$template_file" ]; then
		while IFS= read -r v; do
			known_vars+="
$v"
		done < <(grep -oP 'export \K[A-Z_][A-Z_0-9]*' "$template_file" 2>/dev/null || true)
	fi

	for comp_dir in "$comp_dir"/*/; do
		local comp; comp=$(basename "$comp_dir")
		local kfile="$comp_dir/kustomization.yaml"

		if [ ! -f "$kfile" ]; then
			echo "ERROR: $comp missing kustomization.yaml"
			errors=$((errors + 1))
			continue
		fi

		# Resources listed exist
		while IFS= read -r resource; do
			[ -z "$resource" ] && continue
			if [ ! -f "$comp_dir/$resource" ] && [ ! -d "$comp_dir/$resource" ]; then
				echo "ERROR: $comp/$resource listed in kustomization.yaml but not found"
				errors=$((errors + 1))
			fi
		done < <(yq '.resources[]' "$kfile" 2>/dev/null)

		# Orphan YAMLs not listed
		for yf in "$comp_dir"*.yaml "$comp_dir"*.yml; do
			[ -f "$yf" ] || continue
			local fn; fn=$(basename "$yf")
			[ "$fn" = "kustomization.yaml" ] && continue
			[ "$fn" = "issuers.yaml" ] && continue  # applied by post.sh
			if ! grep -qF "$fn" "$kfile"; then
				echo "WARN: $comp/$fn not listed in kustomization.yaml"
				warnings=$((warnings + 1))
			fi
		done

		# Overlay kustomization check
		for overlay_dir in "$comp_dir"/overlays/*/; do
			[ -d "$overlay_dir" ] || continue
			local overlay; overlay=$(basename "$overlay_dir")
			if [ ! -f "$overlay_dir/kustomization.yaml" ]; then
				echo "ERROR: $comp overlay '$overlay' missing kustomization.yaml"
				errors=$((errors + 1))
			fi
		done

		# Env var references not in known vars
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

	local template_file="$ATLAS_ROOT/targets/$target/VARS.template.sh"
	local known_vars="MY_UID
TARGET
DOCKER_GID
FRPC_USER
COMPOSE_STATE_DIR"
	if [ -f "$template_file" ]; then
		while IFS= read -r v; do
			known_vars+="
$v"
		done < <(grep -oP 'export \K[A-Z_][A-Z_0-9]*' "$template_file" 2>/dev/null || true)
	fi

	# Scan compose file + templates
	for f in "$ATLAS_ROOT/targets/$target/compose/compose.yaml" "$ATLAS_ROOT/targets/$target/compose/templates"/*; do
		[ -f "$f" ] || continue
		while IFS= read -r var; do
			[ -z "$var" ] && continue
			if echo "$known_vars" | grep -qx "$var"; then continue; fi
			echo "WARN: $f references '\$$var' but it's not defined in VARS template"
			warnings=$((warnings + 1))
		done < <(grep -hEo '\$[A-Z_][A-Z_0-9]*|\$\{[A-Z_][A-Z_0-9]*\}' "$f" 2>/dev/null | sed 's/^\$//;s/[{}]//g' | sort -u)
	done

	# Docker Compose dry-run
	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		if [ -f "$COMPOSE_STATE_DIR/compose.yaml" ]; then
			if ! docker compose -f "$COMPOSE_STATE_DIR/compose.yaml" config --dry-run >/dev/null 2>&1; then
				echo "ERROR: docker compose config validation failed"
				errors=$((errors + 1))
			fi
		fi
	fi

	echo ""
	echo "Compose validation: $errors errors, $warnings warnings"
	return $(( errors > 0 ? 1 : 0 ))
}

