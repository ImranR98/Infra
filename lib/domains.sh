#!/bin/bash
# Domain listing for Atlas.

list_domains() {
	local target="${1:-$TARGET}"
	ensure_envsubst_vars

	if [ -d "$ATLAS_ROOT/targets/$target/k3s" ]; then
		grep -rohP "Host\(\x60[^\x60]+\x60\)" --include="*.yaml" "$ATLAS_ROOT/targets/$target/k3s" | \
			sed "s/.*\x60\([^\x60]*\)\x60.*/\1/" | \
			grep -v "\.localhost" | \
			envsubst "$ENVSUBST_VARS" | \
			sort -u
	fi

	if [ -f "$ATLAS_ROOT/targets/$target/compose/compose.yaml" ]; then
		sed -n 's/.*Host(`\([^`]*\)`).*/\1/p' "$ATLAS_ROOT/targets/$target/compose/compose.yaml" | \
			sort -u | \
			envsubst "$ENVSUBST_VARS"
	fi
}
