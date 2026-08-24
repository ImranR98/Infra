#!/bin/bash
# DESC: Join a remote node to the cluster via SSH (run from server)
set -euo pipefail

source "$INFRA_ROOT/lib/common.sh"

CLIENT_IP="${1:?Usage: $0 <client-ip> <ssh-user> [agent|server]}"
SSH_USER="${2:?Usage: $0 <client-ip> <ssh-user> [agent|server]}"
ROLE="${3:-agent}"
case "$ROLE" in agent|server) ;; *) echo "Usage: $0 <client-ip> <ssh-user> [agent|server]" >&2; exit 1 ;; esac

# The node-configuration questions (GPU label, taint, Longhorn) are read from
# this terminal. A non-interactive invocation (e.g. ssh without -t) would make
# every `read` hit EOF instantly and silently default to "n" — refuse instead.
if [ ! -t 0 ]; then
    echo "Error: the join prompts need an interactive terminal on the control plane." >&2
    echo "Run this command in a terminal on the server, or with: ssh -t <server> ..." >&2
    exit 1
fi

echo "[$(date +%T)] Args: CLIENT_IP=$CLIENT_IP SSH_USER=$SSH_USER ROLE=$ROLE"

if ! command -v ssh >/dev/null 2>&1; then
    echo "Error: ssh is required for remote join." >&2
    exit 1
fi
echo "[$(date +%T)] ssh: found"

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: kubectl not found. Are you on the control-plane node?" >&2
    exit 1
fi
echo "[$(date +%T)] kubectl: found"

echo "[$(date +%T)] Reading K3s token from /var/lib/rancher/k3s/server/token..."
SU=$(get_sudo_cmd)
echo "[$(date +%T)] Using privilege command: $SU"
TOKEN=$($SU cat /var/lib/rancher/k3s/server/token)
if [ -z "$TOKEN" ]; then
    echo "Error: cannot read K3s token (empty). Are you on the control-plane node?" >&2
    exit 1
fi
echo "[$(date +%T)] Token: read successfully (${#TOKEN} chars)"

echo "[$(date +%T)] Resolving server IP..."
SERVER_IP=$(kubectl get node "$(hostname)" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null) || SERVER_IP=""
if [ -z "$SERVER_IP" ]; then
    echo "Error: could not determine server IP from kubectl" >&2
    exit 1
fi
SERVER_URL="https://${SERVER_IP}:6443"
echo "[$(date +%T)] Server IP: $SERVER_IP"

echo ""
echo "=== Joining $CLIENT_IP as $ROLE ==="
echo "Server IP: $SERVER_IP"
echo ""

installer=$(mktemp /tmp/k3s-agent-install.XXXXXX)
trap 'rm -f "$installer"' EXIT
echo "[$(date +%T)] Installer script: $installer"

cat > "$installer" << 'ENDSCRIPT'
#!/bin/bash
set -euo pipefail
SERVER_URL="${1:?}"
TOKEN="${2:?}"
ROLE="${3:-agent}"

INFRA_ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$INFRA_ROOT/lib/common.sh"

echo "[$(date +%T)] Client: starting join for role=$ROLE"

if [ "$(id -u)" != 0 ]; then
    SU=$(get_sudo_cmd)
    echo "[$(date +%T)] Client: not root, escalating via $SU"
    if [ "$SU" = "sudo" ]; then
        exec sudo -E bash "$0" "$@"
    else
        exec run0 bash "$0" "$@"
    fi
fi
echo "[$(date +%T)] Client: running as root"

echo "=== Downloading K3s installer ==="
echo "[$(date +%T)] Client: downloading K3s installer..."
download_k3s_installer
echo "[$(date +%T)] Client: installer downloaded"

echo "=== Installing K3s $ROLE ==="
NODE_IP=$(get_node_ip) || NODE_IP=""
echo "[$(date +%T)] Client: node IP = ${NODE_IP:-detected-auto}"
mkdir -p /etc/rancher/k3s/config.yaml.d

if [ "$ROLE" = "server" ]; then
    echo "[$(date +%T)] Client: writing server config..."
    write_k3s_config server "$NODE_IP" /etc/rancher/k3s/config.yaml.d/10-server-join.yaml false
    echo "[$(date +%T)] Client: running k3s server installer..."
    "$K3S_SCRIPT" server --server "$SERVER_URL" --token "$TOKEN"
else
    echo "[$(date +%T)] Client: writing agent config..."
    write_k3s_config agent "$NODE_IP" /etc/rancher/k3s/config.yaml.d/50-agent.yaml false
    echo "[$(date +%T)] Client: running k3s agent installer..."
    "$K3S_SCRIPT" agent --server "$SERVER_URL" --token "$TOKEN"
fi
echo "[$(date +%T)] Client: K3s $ROLE installer completed"
rm -f "$K3S_SCRIPT"

echo "=== Configuring firewall ==="
echo "[$(date +%T)] Client: configuring firewall..."
configure_k3s_firewall
echo "[$(date +%T)] Client: firewall configured"
configure_k3s_sysctl
echo "[$(date +%T)] Client: sysctl configured"
echo "K3s $ROLE installed."
ENDSCRIPT

echo "[$(date +%T)] Syncing files to client..."
ssh "${SSH_USER}@${CLIENT_IP}" "mkdir -p /tmp/lib" 2>/dev/null
rsync -az "$installer" "${SSH_USER}@${CLIENT_IP}:/tmp/agent-install.sh"
echo "[$(date +%T)] Installer synced"
rsync -az "$INFRA_ROOT/lib/" "${SSH_USER}@${CLIENT_IP}:/tmp/lib/"
echo "[$(date +%T)] Lib files synced"

echo "[$(date +%T)] Executing installer on client..."
ssh -t "${SSH_USER}@${CLIENT_IP}" \
    "INFRA_INTERACTIVE=true bash /tmp/agent-install.sh '${SERVER_URL}' '${TOKEN}' '${ROLE}'"
echo "[$(date +%T)] Installer completed on client"

echo "Cleaning up client..."
ssh "${SSH_USER}@${CLIENT_IP}" "rm -rf /tmp/lib /tmp/agent-install.sh" 2>/dev/null || true
echo "[$(date +%T)] Client cleanup done"

echo ""
echo "[$(date +%T)] Waiting for cluster to register new node..."
wait_for_k3s_cluster
echo "[$(date +%T)] Cluster ready"

echo "Ready nodes:"
kubectl get nodes

# Resolve the joined node's name from its IP. The old kubectl jsonpath with a
# nested filter is invalid ("unterminated filter") — under `set -euo pipefail`
# with stderr discarded it silently killed the script right before the
# interactive prompts. jq is a documented prereq; fail loudly if unresolved.
NODE_NAME=$(kubectl get nodes -o json 2>/dev/null | jq -r --arg ip "$CLIENT_IP" '
    .items[] | select((.status.addresses // []) | any(.address == $ip)) | .metadata.name
' 2>/dev/null | head -1) || true
if [ -z "$NODE_NAME" ]; then
    echo "[$(date +%T)] Error: could not find a node with IP $CLIENT_IP in the cluster." >&2
    echo "The agent may not have registered yet — wait a moment and re-run, or check: kubectl get nodes" >&2
    exit 1
fi
echo ""
echo "=================================================================="
echo " Answer the following questions to configure node: $NODE_NAME"
echo "=================================================================="

read -r -p "Does $NODE_NAME have an AMD GPU? [y/N] " response
case "$response" in [yY]|[yY][eE][sS])
    kubectl label node "$NODE_NAME" has-amdgpu=true --overwrite
    echo "Labeled $NODE_NAME with has-amdgpu=true."
    ;;
esac

read -r -p "Should $NODE_NAME get the 'scheduling-discouraged' taint? (pods only land here with explicit toleration, e.g. GPU workloads) [y/N] " response
case "$response" in [yY]|[yY][eE][sS])
    kubectl taint node "$NODE_NAME" scheduling-discouraged=true:PreferNoSchedule --overwrite
    echo "Tainted $NODE_NAME with scheduling-discouraged=true:PreferNoSchedule."
    ;;
esac

read -r -p "Should $NODE_NAME store Longhorn replicas? [y/N] " response
case "$response" in [yY]|[yY][eE][sS])
    kubectl label node "$NODE_NAME" node.longhorn.io/create-default-disk=true --overwrite
    echo "Labeled $NODE_NAME with node.longhorn.io/create-default-disk=true."
    CURRENT_REPLICAS=$(kubectl -n longhorn-system get setting.longhorn.io default-replica-count -o jsonpath='{.value}' 2>/dev/null || echo 0)
    NEW_REPLICAS=$((CURRENT_REPLICAS + 1))
    kubectl -n longhorn-system patch setting.longhorn.io default-replica-count --type=merge -p "{\"value\":\"$NEW_REPLICAS\"}"
    echo "Longhorn replica count auto-incremented: $CURRENT_REPLICAS → $NEW_REPLICAS"
    ;;
*)
    # Without this label, Longhorn's create-default-disk setting creates a
    # disk on every unlabeled node — preventing it is required to keep the
    # node replica-free (volume attach still works, replicas are not placed).
    kubectl label node "$NODE_NAME" node.longhorn.io/create-default-disk=false --overwrite
    echo "Labeled $NODE_NAME with node.longhorn.io/create-default-disk=false."
    echo "Longhorn will attach existing volumes to $NODE_NAME but will not place replicas there."
    ;;
esac

echo ""
echo "Done. Node join completed."
