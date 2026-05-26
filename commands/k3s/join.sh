#!/bin/bash
set -euo pipefail

source "$ATLAS_ROOT/lib/common.sh"

SERVER_IP="${1:-}"
if [ -z "$SERVER_IP" ]; then
	echo "Usage: $0 <server-ip>" >&2
	echo "  Joins this node to an existing K3s cluster as a worker." >&2
	exit 1
fi

if [ "$(id -u)" != 0 ]; then
	exec $(get_sudo_cmd) bash "$0" "$@"
fi

echo "=== Downloading K3s installer ==="
download_k3s_installer

echo ""
read -rsp "Enter the K3s join token (found at /var/lib/rancher/k3s/server/token on the control-plane node): " TOKEN
echo ""

if [ -z "$TOKEN" ]; then
	echo "Error: token must not be empty." >&2
	rm -f "$K3S_SCRIPT"
	exit 1
fi

echo "=== Installing K3s agent ==="
"$K3S_SCRIPT" agent --server "https://$SERVER_IP:6443" --token "$TOKEN"
rm -f "$K3S_SCRIPT"

configure_firewall

echo ""
echo "Waiting for this node to appear in the cluster..."
for i in $(seq 1 30); do
	if kubectl get nodes 2>/dev/null | grep -q "$(hostname)"; then
		echo "Node $(hostname) joined the cluster successfully."
		break
	fi
	[ $i -eq 30 ] && echo "Warning: node not detected after 150s. It may take longer to register."
	sleep 5
done

# Copy kubeconfig from server so kubectl works on this worker.
# Uncomment the block below if you want kubectl access on worker nodes.
#
# echo ""
# echo "=== Copying kubeconfig from server ==="
# mkdir -p ~/.kube
# K3S_URL="${K3S_URL:-https://$SERVER_IP:6443}"
# scp "root@$SERVER_IP:/etc/rancher/k3s/k3s.yaml" ~/.kube/config
# sed -i "s|127.0.0.1|$SERVER_IP|g" ~/.kube/config
# echo "kubeconfig written to ~/.kube/config"

echo ""
echo "Done. Worker node $(hostname) has joined the cluster."
echo "Run 'kubectl get nodes' on the control-plane to confirm."
