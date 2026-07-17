#!/bin/bash
# DESC: Join a remote node to the cluster via SSH (run from server)
set -euo pipefail

source "$ATLAS_ROOT/lib/common.sh"

CLIENT_IP="${1:?Usage: $0 <client-ip> <ssh-user> [agent|server]}"
SSH_USER="${2:?Usage: $0 <client-ip> <ssh-user> [agent|server]}"
ROLE="${3:-agent}"
case "$ROLE" in agent|server) ;; *) echo "Usage: $0 <client-ip> <ssh-user> [agent|server]" >&2; exit 1 ;; esac

if ! command -v ssh >/dev/null 2>&1; then
	echo "Error: ssh is required for remote join." >&2
	exit 1
fi
if ! command -v kubectl >/dev/null 2>&1; then
	echo "Error: kubectl not found. Are you on the control-plane node?" >&2
	exit 1
fi

TOKEN=$(cat /var/lib/rancher/k3s/server/token 2>/dev/null) || {
	echo "Error: cannot read K3s token. Are you on the control-plane node?" >&2
	exit 1
}
SERVER_IP=$(kubectl get node "$(hostname)" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null) || SERVER_IP=""
SERVER_URL="https://${SERVER_IP}:6443"

echo "Joining $CLIENT_IP as $ROLE..."
echo "Server IP: $SERVER_IP"
echo ""

# --- send and run prep scripts on client ---
echo "=== Host preparation ==="
rsync -az "$ATLAS_ROOT/commands/k3s/prep-node.sh" "${SSH_USER}@${CLIENT_IP}:/tmp/"
ssh -t "${SSH_USER}@${CLIENT_IP}" "sudo bash /tmp/prep-node.sh" || {
	echo "Error: prep-node.sh failed on $CLIENT_IP" >&2; exit 1; }

if [ "$ROLE" = "server" ]; then
	rsync -az "$ATLAS_ROOT/commands/k3s/prep-control-plane.sh" "${SSH_USER}@${CLIENT_IP}:/tmp/"
	ssh -t "${SSH_USER}@${CLIENT_IP}" \
		"sudo MAYASTOR_POOL_DIR='${MAYASTOR_POOL_DIR}' bash /tmp/prep-control-plane.sh" || {
		echo "Error: prep-control-plane.sh failed on $CLIENT_IP" >&2; exit 1; }
fi

# --- build and sync K3s installer ---
echo ""
echo "=== Running K3s installer on client ==="
installer=$(mktemp /tmp/k3s-agent-install.XXXXXX)
trap 'rm -f "$installer"' EXIT

cat > "$installer" << 'ENDSCRIPT'
#!/bin/bash
set -euo pipefail
SERVER_URL="${1:?}"
TOKEN="${2:?}"
ROLE="${3:-agent}"

ATLAS_ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ATLAS_ROOT/lib/common.sh"

if [ "$(id -u)" != 0 ]; then
	SUDOCMD=$(get_sudo_cmd)
	if [ "$SUDOCMD" = "sudo" ]; then
		exec sudo -E bash "$0" "$@"
	else
		exec run0 bash "$0" "$@"
	fi
fi

echo "=== Downloading K3s installer ==="
download_k3s_installer

echo "=== Installing K3s $ROLE ==="
NODE_IP=$(get_node_ip) || NODE_IP=""
mkdir -p /etc/rancher/k3s/config.yaml.d

if [ "$ROLE" = "server" ]; then
	cat > /etc/rancher/k3s/config.yaml.d/10-server-join.yaml <<K3SEOF
selinux: true
flannel-backend: wireguard-native
node-ip: $NODE_IP
flannel-iface-regex: "^(eth|ens|enp|eno|enx|wlan|wlp|wlo|bond|ib)"
node-label:
  - "external-exposed=true"
  - "hostpath-main=true"
K3SEOF
	"$K3S_SCRIPT" server --server "$SERVER_URL" --token "$TOKEN"
else
	cat > /etc/rancher/k3s/config.yaml.d/50-agent.yaml <<K3SEOF
selinux: true
flannel-backend: wireguard-native
node-ip: $NODE_IP
flannel-iface-regex: "^(eth|ens|enp|eno|enx|wlan|wlp|wlo|bond|ib)"
K3SEOF
	"$K3S_SCRIPT" agent --server "$SERVER_URL" --token "$TOKEN"
fi
rm -f "$K3S_SCRIPT"

echo "=== Configuring firewall ==="
configure_k3s_firewall
echo "K3s $ROLE installed."
ENDSCRIPT

echo "Syncing files to client..."
ssh "${SSH_USER}@${CLIENT_IP}" "mkdir -p /tmp/lib" 2>/dev/null
rsync -az "$installer" "${SSH_USER}@${CLIENT_IP}:/tmp/agent-install.sh"
rsync -az "$ATLAS_ROOT/lib/common.sh" "${SSH_USER}@${CLIENT_IP}:/tmp/lib/"

ssh -t "${SSH_USER}@${CLIENT_IP}" \
	"ATLAS_INTERACTIVE=true bash /tmp/agent-install.sh '${SERVER_URL}' '${TOKEN}' '${ROLE}'"

echo "Cleaning up client..."
ssh "${SSH_USER}@${CLIENT_IP}" "rm -rf /tmp/lib /tmp/agent-install.sh /tmp/prep-node.sh /tmp/prep-control-plane.sh" 2>/dev/null || true

echo ""
wait_for_k3s_cluster

if [ "$ROLE" = "server" ]; then
	NODE_NAME=$(ssh "${SSH_USER}@${CLIENT_IP}" "hostname -s" 2>/dev/null || true)
	[ -n "$NODE_NAME" ] && kubectl label node "$NODE_NAME" openebs.io/engine=mayastor --overwrite 2>/dev/null || true
fi

echo "Ready nodes:"
kubectl get nodes
echo "Done. Node join completed."
