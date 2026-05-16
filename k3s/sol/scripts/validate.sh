#!/bin/bash
set -euo pipefail
shopt -s nullglob

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
ERRORS=0
WARNINGS=0

# Files intentionally excluded from kustomization.yaml (applied by post.sh or not K8s resources)
KNOWN_SKIP_PATTERNS=(
	"issuers.yaml"
)

# Gather all known env vars from VARS templates
KNOWN_ENV_VARS=""
for f in "$ROOT_DIR/../../vars/VARS.common.sh" "$ROOT_DIR/../../vars/VARS.sol.sh"; do
	if [ -f "$f" ]; then
		KNOWN_ENV_VARS+=$(grep -oP 'export \K[A-Z_]+' "$f" || true)
		KNOWN_ENV_VARS+="
"
	fi
done

# Internal bash variables used inside YAML command: blocks (not envsubst vars)
KNOWN_ENV_VARS+="
MY_UID
MAIN_NODE_NAME_LOWERCASE
NS
PV
PVC
VOLUMES
"

for comp_dir in "$ROOT_DIR"/components/*/; do
	comp=$(basename "$comp_dir")
	[ "$comp" = "frp" ] || [ "$comp" = "k3s" ] && continue

	if [ ! -f "$comp_dir/kustomization.yaml" ]; then
		echo "ERROR: $comp missing kustomization.yaml"
		ERRORS=$((ERRORS + 1))
		continue
	fi

	# Check resources listed in kustomization.yaml exist
	while IFS= read -r resource; do
		[ -z "$resource" ] && continue
		if [ ! -f "$comp_dir/$resource" ] && [ ! -d "$comp_dir/$resource" ]; then
			echo "ERROR: $comp/$resource listed in kustomization.yaml but not found"
			ERRORS=$((ERRORS + 1))
		fi
	done < <(yq '.resources[]' "$comp_dir/kustomization.yaml" 2>/dev/null)

	# Check for orphaned YAML files not listed in kustomization.yaml
	for yaml_file in "$comp_dir"*.yaml "$comp_dir"*.yml; do
		[ -f "$yaml_file" ] || continue
		filename=$(basename "$yaml_file")
		[ "$filename" = "kustomization.yaml" ] && continue

		_skip=false
		for pattern in "${KNOWN_SKIP_PATTERNS[@]}"; do
			if [ "$filename" = "$pattern" ]; then
				_skip=true
				break
			fi
		done
		$_skip && continue

		if ! grep -q "$filename" "$comp_dir/kustomization.yaml"; then
			echo "WARN: $comp/$filename not listed in kustomization.yaml"
			WARNINGS=$((WARNINGS + 1))
		fi
	done

	# Check that overlays reference valid resources
	for overlay_dir in "$comp_dir"/overlays/*/; do
		[ -d "$overlay_dir" ] || continue
		overlay=$(basename "$overlay_dir")
		if [ ! -f "$overlay_dir/kustomization.yaml" ]; then
			echo "ERROR: $comp overlay '$overlay' missing kustomization.yaml"
			ERRORS=$((ERRORS + 1))
		fi
	done

	# Check for env vars referenced in YAML but not defined in VARS templates
	for yaml_file in "$comp_dir"*.yaml; do
		[ -f "$yaml_file" ] || continue
		while IFS= read -r var; do
			[ -z "$var" ] && continue
			if echo "$KNOWN_ENV_VARS" | grep -qx "$var"; then
				continue
			fi
			echo "WARN: $comp/$(basename "$yaml_file") references '$var' but it's not defined in VARS templates"
			WARNINGS=$((WARNINGS + 1))
		done < <(grep -v '^\s*#' "$yaml_file" 2>/dev/null | grep -oP '\$\{?[A-Z_][A-Z_0-9]+\}?' | sed 's/^\$//;s/[{}]//g' | sort -u)
	done
done

echo ""
echo "Validation complete: $ERRORS errors, $WARNINGS warnings"
if [ $ERRORS -gt 0 ]; then
	exit 1
fi
