#!/bin/bash
# DESC: Join a remote node to the cluster via SSH (run from server)
set -euo pipefail

source "$ATLAS_ROOT/lib/common.sh"

CLIENT_IP="${1:?Usage: $0 <client-ip> <ssh-user>}"
SSH_USER="${2:?Usage: $0 <client-ip> <ssh-user>}"

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

echo "Joining $CLIENT_IP to cluster..."
echo "Server IP: $SERVER_IP"
echo ""

installer=$(mktemp /tmp/k3s-agent-install.XXXXXX)
trap 'rm -f "$installer"' EXIT

cat > "$installer" << 'ENDSCRIPT'
#!/bin/bash
set -euo pipefail
SERVER_URL="${1:?}"
TOKEN="${2:?}"

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

echo "=== Installing K3s agent ==="
"$K3S_SCRIPT" agent --server "$SERVER_URL" --token "$TOKEN"
rm -f "$K3S_SCRIPT"

echo "=== Configuring firewall ==="
configure_firewall
echo "K3s agent installed."
ENDSCRIPT

echo "Syncing files to client..."
ssh "${SSH_USER}@${CLIENT_IP}" "mkdir -p /tmp/lib" 2>/dev/null
rsync -az "$installer" "${SSH_USER}@${CLIENT_IP}:/tmp/agent-install.sh"
rsync -az "$ATLAS_ROOT/lib/common.sh" "${SSH_USER}@${CLIENT_IP}:/tmp/lib/"

echo "Running agent installer on client..."
ssh -t "${SSH_USER}@${CLIENT_IP}" \
	"ATLAS_INTERACTIVE=true bash /tmp/agent-install.sh '${SERVER_URL}' '${TOKEN}'"

echo "Cleaning up client..."
ssh "${SSH_USER}@${CLIENT_IP}" "rm -rf /tmp/lib /tmp/agent-install.sh" 2>/dev/null || true

echo ""
echo "Waiting for node to register..."
for i in $(seq 1 30); do
	if kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -q Ready; then
		echo "Ready nodes:"
		kubectl get nodes
		break
	fi
	if [ $i -eq 30 ]; then
		echo "Warning: node may take longer to register."
	fi
	sleep 5
done
echo "Done. Node join initiated."
