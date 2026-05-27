#!/bin/bash
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"

GROUP="${1:?Usage: $0 <base|apps> [apply|initial|delete]}"
MODE="${2:-apply}"
case "$MODE" in apply|initial|delete) ;; *) echo "Usage: $0 <base|apps> [apply|initial|delete]" >&2; exit 1 ;; esac

case "$GROUP" in
	base)
		COMPONENTS=(namespaces nfs-server csi-driver-nfs longhorn cert-manager traefik crowdsec authelia ntfy)
		if [ "$MODE" = "delete" ]; then
			kubectl get pvc -A --no-headers 2>/dev/null | grep -q Bound && { echo "Bound PVCs exist. Delete apps before base components." >&2; exit 1; }
		fi
		;;
	apps)
		COMPONENTS=(immich logtfy jellyfin navidrome mdscl mosquitto homeassistant ollama nextcloud freshrss opodsync dscpln opencanary fmd syncthing)
		;;
	*)
		echo "Unknown group: $GROUP (valid: base, apps)" >&2; exit 1 ;;
esac

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
	if [ "$GROUP" = "base" ] && [ "$comp" = "namespaces" ]; then
		echo "Waiting for network policy propagation..."
		sleep 15
	fi
done