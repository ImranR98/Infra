#!/bin/bash
# DESC: Join a remote node to the cluster via SSH (run from server)
set -euo pipefail

source "$INFRA_ROOT/lib/common.sh"

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

echo "=== Joining $CLIENT_IP as $ROLE ==="
echo "Server IP: $SERVER_IP"
echo ""
installer=$(mktemp /tmp/k3s-agent-install.XXXXXX)
trap 'rm -f "$installer"' EXIT

cat > "$installer" << 'ENDSCRIPT'
#!/bin/bash
set -euo pipefail
SERVER_URL="${1:?}"
TOKEN="${2:?}"
ROLE="${3:-agent}"

INFRA_ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$INFRA_ROOT/lib/common.sh"

if [ "$(id -u)" != 0 ]; then
    SU=$(get_sudo_cmd)
    if [ "$SU" = "sudo" ]; then
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
    write_k3s_config server "$NODE_IP" /etc/rancher/k3s/config.yaml.d/10-server-join.yaml false
    "$K3S_SCRIPT" server --server "$SERVER_URL" --token "$TOKEN"
else
    write_k3s_config agent "$NODE_IP" /etc/rancher/k3s/config.yaml.d/50-agent.yaml false
    "$K3S_SCRIPT" agent --server "$SERVER_URL" --token "$TOKEN"
fi
rm -f "$K3S_SCRIPT"

echo "=== Configuring firewall ==="
configure_k3s_firewall
configure_k3s_sysctl
echo "K3s $ROLE installed."
ENDSCRIPT

echo "Syncing files to client..."
ssh "${SSH_USER}@${CLIENT_IP}" "mkdir -p /tmp/lib" 2>/dev/null
rsync -az "$installer" "${SSH_USER}@${CLIENT_IP}:/tmp/agent-install.sh"
rsync -az "$INFRA_ROOT/lib/common.sh" "${SSH_USER}@${CLIENT_IP}:/tmp/lib/"

ssh -t "${SSH_USER}@${CLIENT_IP}" \
    "INFRA_INTERACTIVE=true bash /tmp/agent-install.sh '${SERVER_URL}' '${TOKEN}' '${ROLE}'"

echo "Cleaning up client..."
ssh "${SSH_USER}@${CLIENT_IP}" "rm -rf /tmp/lib /tmp/agent-install.sh" 2>/dev/null || true

echo ""
wait_for_k3s_cluster

echo "Ready nodes:"
kubectl get nodes
echo "Done. Node join completed."
