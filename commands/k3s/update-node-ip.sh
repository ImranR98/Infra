#!/bin/bash
# DESC: Update K3s node IP after a network change
set -euo pipefail

source "$ATLAS_ROOT/lib/common.sh"

SU="$(get_sudo_cmd)"

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: kubectl not found. Is K3s installed?" >&2
    exit 1
fi

node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$node_name" ]; then
    echo "Error: no K3s nodes found. Is the cluster running?" >&2
    exit 1
fi

new_ip=$(get_node_ip) || { echo "Error: could not detect primary IP" >&2; exit 1; }
current_node_ip=$(kubectl get node "$node_name" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)

if [ "$current_node_ip" = "$new_ip" ]; then
    echo "Node IP matches ($new_ip). Nothing to do."
    exit 0
fi

echo "Updating K3s node IP: $current_node_ip → $new_ip"

config_dir="/etc/rancher/k3s/config.yaml.d"
$SU bash -c 'mkdir -p "$1"' _ "$config_dir"
printf 'node-ip: %s\n' "$new_ip" | $SU bash -c 'tee "$1" >/dev/null' _ "$config_dir/20-node-ip.yaml"

$SU bash -c 'systemctl daemon-reload'
if systemctl is-active --quiet k3s.service 2>/dev/null; then
    $SU bash -c 'systemctl restart k3s.service'
fi

echo "Waiting for cluster to be ready..."
wait_for_k3s_cluster

echo "Re-applying network policies with updated API server subnet..."
bash "$ATLAS_ROOT/commands/k3s/deploy.sh" namespaces apply

echo "Done. K3s node IP updated to $new_ip."
