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

script=$(mktemp /tmp/k3s-join-script.XXXXXX)
trap 'rm -f "$script"' EXIT

{
	echo '#!/bin/bash'
	echo 'set -euo pipefail'
	echo 'SERVER_URL="$1"'
	echo 'TOKEN="$2"'

	declare -f download_k3s_installer
	declare -f configure_firewall

	cat << 'BODY'

SUDO=""
if [ "$(id -u)" != 0 ]; then
	if command -v run0 >/dev/null 2>&1; then
		SUDO="run0"
	else
		SUDO="sudo"
	fi
fi

echo "=== Downloading K3s installer ==="
download_k3s_installer

echo "=== Installing K3s agent ==="
$SUDO "$K3S_SCRIPT" agent --server "$SERVER_URL" --token "$TOKEN"
rm -f "$K3S_SCRIPT"

echo ""
echo "=== Configuring firewall ==="
configure_firewall
echo "K3s agent installed."
BODY
} > "$script"

scp "$script" "${SSH_USER}@${CLIENT_IP}:/tmp/k3s-join-script.sh"
ssh -t "${SSH_USER}@${CLIENT_IP}" \
	"bash /tmp/k3s-join-script.sh '${SERVER_URL}' '${TOKEN}'"
ssh "${SSH_USER}@${CLIENT_IP}" "rm /tmp/k3s-join-script.sh" 2>/dev/null || true

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
