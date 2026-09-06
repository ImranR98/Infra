#!/bin/bash
# DESC: Bootstrap a K3s control-plane node
set -euo pipefail

[ -z "${INFRA_ROOT:-}" ] && INFRA_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
source "$INFRA_ROOT/lib/common.sh"

if [ "$(id -u)" != 0 ]; then
    exec $(get_sudo_cmd) env TARGET="$TARGET" INFRA_ROOT="$INFRA_ROOT" K3S_STATE_DIR="$K3S_STATE_DIR" MY_UID="$MY_UID" bash "$0" "$@"
fi

DID_COMPLETE=false
_cleanup() {
    if [ "$DID_COMPLETE" = false ]; then
        echo "It appears the script did not complete." >&2
    fi
    rm -f "$K3S_SCRIPT"
}
trap _cleanup EXIT

echo "NOTE: K3s requires a fixed IP on this network. If the IP changes, run: task <target>:k3s:update-node-ip"
echo ""

echo "=== Downloading K3s installer ==="
download_k3s_installer


# Write K3s config drop-in files before installing so the first start picks them up
NODE_IP=$(get_node_ip) || NODE_IP=""
mkdir -p /etc/rancher/k3s/config.yaml.d
write_k3s_config server "$NODE_IP" /etc/rancher/k3s/config.yaml.d/10-server.yaml true
echo "K3s config drop-in written to /etc/rancher/k3s/config.yaml.d/10-server.yaml"

# Containerd CDI drop-in: enables CDI so the cdi-specs component can grant
# specific host devices (ConBee II, /dev/dri) to pods without privileged.
write_containerd_cdi_dropin

echo ""
echo "=== Installing K3s server ==="
"$K3S_SCRIPT"

echo ""
echo "=== Setting up kubectl group access ==="
groupadd -f kubectl
if ! grep -E '^kubectl:' /etc/group >/dev/null 2>&1; then
    # Workaround for secureblue
    grep -E '^kubectl:' /usr/lib/group | tee -a /etc/group >/dev/null
fi
chgrp -R kubectl /etc/rancher/k3s
K3S_CONFIG_OWNER="$(echo "${SUDO_USER:-$USER}")"
usermod -aG kubectl "$K3S_CONFIG_OWNER"
echo "Added $K3S_CONFIG_OWNER to the kubectl group."
echo "Log out and back in for group membership to take effect, or use: newgrp kubectl"

echo ""
echo "=== Node Labels ==="
kubectl label node "$(hostname)" node.longhorn.io/create-default-disk=true --overwrite
echo "$(hostname) labeled as a Longhorn storage node."
echo "If this node has an AMD GPU, also label it:"
echo "  kubectl label node $(hostname) has-amdgpu=true --overwrite"
kubectl label node "$(hostname)" has-homeassistant-hardware=true --overwrite
echo "$(hostname) labeled as a homeassistant hardware node."

configure_k3s_firewall
configure_k3s_sysctl

echo ""
echo "Waiting for cluster to be ready..."
systemctl enable --now k3s
wait_for_k3s_cluster

DID_COMPLETE=true
echo "Done. K3s control-plane node initialized."
