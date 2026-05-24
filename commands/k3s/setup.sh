#!/bin/bash
# Installs k3s
# Assumed that it's okay for all user accounts to read k3s config

set -euo pipefail

: ${ATLAS_ROOT:="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"}
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

K3S_SCRIPT="$(mktemp /tmp/k3s-install.XXXXXX)"
curl -fsSL --connect-timeout 30 --max-time 120 --retry 3 https://get.k3s.io -o "$K3S_SCRIPT"

# Verify the install script SHA256 checksum
K3S_SCRIPT_SHA256=$(curl -fsSL --connect-timeout 10 --max-time 30 https://github.com/k3s-io/k3s/raw/main/install.sh 2>/dev/null | sha256sum | cut -d' ' -f1)
DOWNLOADED_SHA256=$(sha256sum $K3S_SCRIPT | cut -d' ' -f1)
if [ -z "$K3S_SCRIPT_SHA256" ]; then echo "Error: could not verify K3s install script (GitHub unreachable)." >&2; exit 1; elif [ "$K3S_SCRIPT_SHA256" != "$DOWNLOADED_SHA256" ]; then
    echo "Error: K3s install script checksum mismatch." >&2
    echo "  Expected: $K3S_SCRIPT_SHA256" >&2
    echo "  Got:      $DOWNLOADED_SHA256" >&2
    rm -f $K3S_SCRIPT
    exit 1
fi

# Only needed on secureblue
# semodule --disable=userns_deny_unconfined_relabels # Required for K3s Flannel unfortunately
# sed -i 's/# rpm_install_extra_args/rpm_install_extra_args/g' $K3S_SCRIPT

chmod +x $K3S_SCRIPT
$K3S_SCRIPT --write-kubeconfig-mode 644 --selinux

# Label the node for hostPath volume scheduling
echo "Labeling node for hostPath volume scheduling..."
# Wait for k3s to be ready and kubectl to work
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
	echo "You can label the node manually later with:" >&2
	echo "  kubectl label node <node-name> hostpath-main=true --overwrite" >&2
	exit 1
else
	# Determine node name (use hostname, fallback to first node from kubectl)
	NODE_NAME="$(hostname)"
	if ! kubectl get node "$NODE_NAME" >/dev/null 2>&1; then
		echo "Node name '$NODE_NAME' not found in Kubernetes cluster. Using first available node."
		NODE_NAME="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')"
	fi

	if [ -n "$NODE_NAME" ]; then
		# Label the node for hostPath volumes
		if kubectl label node "$NODE_NAME" hostpath-main=true --overwrite 2>/dev/null; then
			echo "Node $NODE_NAME labeled with hostpath-main=true"
		else
			echo "Warning: Failed to label node $NODE_NAME. You can label it manually later:"
			echo "  kubectl label node $NODE_NAME hostpath-main=true --overwrite"
		fi
	else
		echo "Error: Could not determine node name. Skipping labeling."
	fi
fi


DID_COMPLETE=true


# ---- Firewall section ----

# Check for firewalld
if ! command -v firewall-cmd >/dev/null 2>&1; then
	echo "Warning: firewall-cmd not found. Skipping firewall configuration."
	echo "If using a different firewall, ensure interfaces cni0 and flannel.1 are trusted."
else

firewall-cmd --permanent --zone=trusted --add-interface=cni0 2>/dev/null || true
firewall-cmd --permanent --zone=trusted --add-interface=flannel.1 2>/dev/null || true
firewall-cmd --reload
fi

echo "Firewall configured. Note: VPNs may interfere with cluster networking and should run on an upstream router."
