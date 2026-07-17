#!/bin/bash
# DESC: Bootstrap a K3s control-plane node
set -euo pipefail

[ -z "${ATLAS_ROOT:-}" ] && ATLAS_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
source "$ATLAS_ROOT/lib/common.sh"

if [ "$(id -u)" != 0 ]; then
	exec $(get_sudo_cmd) bash "$0" "$@"
fi

DID_COMPLETE=false
cleanup() {
	if [ "$DID_COMPLETE" = false ]; then
		echo "It appears the script did not complete." >&2
	fi
	rm -f "$K3S_SCRIPT"
}
trap cleanup EXIT

echo "NOTE: K3s requires a fixed IP on this network. If the IP changes, run: ./atlas.sh <target> k3s update-node-ip"
echo ""

echo "=== Downloading K3s installer ==="
download_k3s_installer

# Only needed on secureblue
# semodule --disable=userns_deny_unconfined_relabels # Required for K3s Flannel unfortunately
# sed -i 's/# rpm_install_extra_args/rpm_install_extra_args/g' $K3S_SCRIPT

# Write K3s config drop-in files before installing so the first start picks them up
NODE_IP=$(get_node_ip) || NODE_IP=""
mkdir -p /etc/rancher/k3s/config.yaml.d
cat > /etc/rancher/k3s/config.yaml.d/10-server.yaml <<K3SEOF
selinux: true
write-kubeconfig-mode: "0640"
cluster-init: true
flannel-backend: wireguard
node-ip: $NODE_IP
flannel-iface-regex: "^(eth|ens|enp|eno|enx|wlan|wlp|wlo|bond|ib)"
node-label:
  - "hostpath-main=true"
  - "external-exposed=true"
K3SEOF
echo "K3s config drop-in written to /etc/rancher/k3s/config.yaml.d/10-server.yaml"

echo ""
echo "=== Host preparation ==="
export MAYASTOR_POOL_DIR="${MAYASTOR_POOL_DIR:-/var/local/mayastor-install/io-engine}"
bash "$ATLAS_ROOT/commands/k3s/prep-node.sh"
bash "$ATLAS_ROOT/commands/k3s/prep-control-plane.sh"

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
echo "If this node has an AMD GPU, label it for GPU-accelerated workloads:"
echo "  kubectl label node $(hostname) has-amdgpu=true --overwrite"

configure_k3s_firewall

echo ""
echo "Waiting for cluster to be ready..."
systemctl enable --now k3s
wait_for_k3s_cluster

kubectl label node "$(hostname)" openebs.io/engine=mayastor --overwrite

DID_COMPLETE=true
echo "Done. K3s control-plane node initialized."
