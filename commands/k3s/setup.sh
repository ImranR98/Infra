#!/bin/bash
# DESC: Bootstrap a K3s control-plane node

set -euo pipefail

source "$ATLAS_ROOT/lib/common.sh"

if [ "$(id -u)" != 0 ]; then
	exec $(get_sudo_cmd) bash "$0" "$@"
fi

if [ -t 0 ]; then
    read -p "WARNING: YOU MUST HAVE A FIXED IP ON THIS NETWORK (ENSURE THIS IS SET IN YOUR OS SETTINGS).
A CHANGE IN IP WILL BREAK K3S NETWORKING! If that does happen, you can update the cluster with: ./atlas.sh sol k3s update-node-ip
Press Enter to continue..." ANYTHING
fi
DID_COMPLETE=false
cleanup() {
	if [ "$DID_COMPLETE" = false ]; then
		echo "It appears the script did not complete." >&2
	fi
	rm -f "$K3S_SCRIPT"
}
trap cleanup EXIT

echo "=== Downloading K3s installer ==="
download_k3s_installer

# Only needed on secureblue
# semodule --disable=userns_deny_unconfined_relabels # Required for K3s Flannel unfortunately
# sed -i 's/# rpm_install_extra_args/rpm_install_extra_args/g' $K3S_SCRIPT

# Write K3s config drop-in files before installing so the first start picks them up
mkdir -p /etc/rancher/k3s/config.yaml.d
cat > /etc/rancher/k3s/config.yaml.d/10-server.yaml <<'K3SEOF'
selinux: true
write-kubeconfig-mode: "0640"
cluster-init: true
node-label:
  - "hostpath-main=true"
  - "external-exposed=true"
K3SEOF
echo "K3s config drop-in written to /etc/rancher/k3s/config.yaml.d/10-server.yaml"

"$K3S_SCRIPT"

# Wait for cluster to be ready
CLUSTER_READY=false
for i in $(seq 1 30); do
	if kubectl get nodes >/dev/null 2>&1; then
		echo "Kubernetes cluster is ready."
		CLUSTER_READY=true
		break
	fi
	echo "Waiting for Kubernetes cluster to be ready... ($i/30)"
	sleep 5
done

if [ "$CLUSTER_READY" = false ]; then
	echo "Error: Could not connect to Kubernetes cluster after 150 seconds." >&2
	exit 1
fi

echo ""
echo "=== Setting up kubectl group access ==="
groupadd -f kubectl
if ! grep -E '^kubectl:' /etc/group >/dev/null 2>&1; then
	# Workaround for secureblue
    grep -E '^kubectl:' /usr/lib/group | tee -a /etc/group >/dev/null
fi
chgrp kubectl /etc/rancher/k3s/k3s.yaml
K3S_CONFIG_OWNER="$(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")"
usermod -aG kubectl "$K3S_CONFIG_OWNER"
echo "Added $K3S_CONFIG_OWNER to the kubectl group."
echo "Log out and back in for group membership to take effect, or use: newgrp kubectl"

echo ""
echo "=== Node Labels ==="
echo "If this node has an AMD GPU, label it for GPU-accelerated workloads:"
echo "  kubectl label node $(hostname) has-amdgpu=true --overwrite"

DID_COMPLETE=true

configure_firewall
