#!/bin/bash
# DESC: Deploy or delete a group of K3s components (base or apps)
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"

GROUP="${1:?Usage: $0 <base|apps> [apply|initial|delete]}"
MODE="${2:-apply}"
case "$MODE" in apply|initial|delete) ;; *) echo "Usage: $0 <base|apps> [apply|initial|delete]" >&2; exit 1 ;; esac

_groups_file="$ATLAS_ROOT/targets/$TARGET/k3s/groups.yaml"
if [ ! -f "$_groups_file" ]; then
	_groups_file="$ATLAS_ROOT/targets/sol/k3s/groups.yaml"
fi
if [ ! -f "$_groups_file" ]; then
	echo "No groups.yaml found for target $TARGET." >&2
	exit 1
fi

COMPONENTS=()
while IFS= read -r comp; do
	[ -n "$comp" ] && COMPONENTS+=("$comp")
done < <(yq ".${GROUP}[]" "$_groups_file" 2>/dev/null)

if [ ${#COMPONENTS[@]} -eq 0 ]; then
	echo "Unknown group: $GROUP (valid groups found in $_groups_file)" >&2
	exit 1
fi

if [ "$MODE" = "delete" ]; then
	if [ "$GROUP" = "base" ]; then
		kubectl get pvc -A --no-headers 2>/dev/null | grep -q Bound && { echo "Bound PVCs exist. Delete apps before base components." >&2; exit 1; }
	fi
	for ((i=${#COMPONENTS[@]}-1; i>=0; i--)); do
		echo "=== ${COMPONENTS[$i]} (delete) ==="
		bash "$ATLAS_ROOT/commands/k3s/install.sh" "${COMPONENTS[$i]}" delete || true
	done
	exit 0
fi

for comp in "${COMPONENTS[@]}"; do
	echo "=== $comp ==="
	bash "$ATLAS_ROOT/commands/k3s/install.sh" "$comp" "$MODE"
done
