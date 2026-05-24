#!/bin/bash
set -euo pipefail

: ${ATLAS_ROOT:="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"}
source "$ATLAS_ROOT/lib/common.sh"

SU="$(get_sudo_cmd)"

get_primary_iface() {
	local iface
	iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
	if [ -z "$iface" ]; then
		echo "Error: no default route found, cannot determine primary interface" >&2
		return 1
	fi
	echo "$iface"
}

get_current_ip() {
	local iface="${1:-}"
	[ -n "$iface" ] || iface=$(get_primary_iface) || return 1
	ip -4 addr show "$iface" | grep -oP 'inet \K[\d.]+'
}

if ! command -v kubectl >/dev/null 2>&1; then
	echo "Error: kubectl not found. Is K3s installed?" >&2
	exit 1
fi

node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$node_name" ]; then
	echo "Error: no K3s nodes found. Is the cluster running?" >&2
	exit 1
fi

iface=$(get_primary_iface)
new_ip=$(get_current_ip "$iface")
current_node_ip=$(kubectl get node "$node_name" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)

if [ "$current_node_ip" = "$new_ip" ]; then
	echo "Node IP matches ($new_ip). Nothing to do."
	exit 0
fi

echo "Updating K3s node IP: $current_node_ip → $new_ip"

config_dir="/etc/rancher/k3s/config.yaml.d"
$SU mkdir -p "$config_dir"
printf 'node-ip: %s\n' "$new_ip" | $SU tee "$config_dir/20-node-ip.yaml" >/dev/null

$SU systemctl daemon-reload
if systemctl is-active --quiet k3s.service 2>/dev/null; then
	$SU systemctl restart k3s.service
fi

echo "Done. K3s node IP updated to $new_ip."
