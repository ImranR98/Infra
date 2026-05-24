#!/bin/bash
# Deploy all base K3s components in the correct order.
# Usage: ./atlas.sh sol k3s base [apply|initial|delete]
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"

MODE="${1:-apply}"
case "$MODE" in apply|initial|delete) ;; *) echo "Usage: $0 [apply|initial|delete]" >&2; exit 1 ;; esac

COMPONENTS=(namespaces nfs-server csi-driver-nfs longhorn cert-manager traefik crowdsec authelia ntfy)

if [ "$MODE" = "delete" ]; then
	_bound_pvcs=$(kubectl get pvc -n apps -n monitoring -n syncthing --no-headers 2>/dev/null | grep -c Bound || true)
	if [ "${_bound_pvcs:-0}" -gt 0 ]; then
		echo "$_bound_pvcs bound PVCs found in apps/monitoring/syncthing namespaces." >&2
		echo "Run './atlas.sh sol k3s apps delete' first to safely drain storage before removing base components." >&2
		exit 1
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
	if [ "$comp" = "namespaces" ] && [ "$MODE" != "delete" ]; then
		echo "Waiting for network policy propagation before continuing..."
		sleep 15
	fi
done
