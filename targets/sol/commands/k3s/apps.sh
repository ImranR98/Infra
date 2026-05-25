#!/bin/bash
# Deploy all app K3s components in the correct order.
# Usage: ./atlas.sh sol k3s apps [apply|initial|delete]
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"

MODE="${1:-apply}"
case "$MODE" in apply|initial|delete) ;; *) echo "Usage: $0 [apply|initial|delete]" >&2; exit 1 ;; esac

COMPONENTS=(immich logtfy jellyfin navidrome mdscl mosquitto homeassistant ollama nextcloud freshrss opodsync dscpln opencanary fmd syncthing)

if [ "$MODE" = "delete" ]; then
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
