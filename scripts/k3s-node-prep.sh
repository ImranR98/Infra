#!/bin/bash
# DESC: Prepare a K3s node: sysctls, firewall
# ports/trusted CIDRs, the kubectl group, pciutils. Runs ON the node as root
# (sudo). Shared by k3s-server.sh and k3s-join.sh.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"

usage() {
    echo "Usage: $(basename "$0")   (run ON the node; root or sudo)"
    exit 1
}

[ "$(id -u)" -eq 0 ] || { echo "Error: must run as root (sudo $0)" >&2; exit 1; }

# ---- sysctls ----------------------------------------------------------------
cat >/etc/sysctl.d/90-k3s.conf <<'EOF'
# K3s node tuning — applied by scripts/k3s-node-prep.sh
fs.inotify.max_user_watches = 6000000
fs.inotify.max_user_instances = 512
user.max_user_namespaces = 28633
EOF
sysctl --system >/dev/null

# ---- firewall (K3s ports + pod/service CIDRs) --------------------------------
if command -v firewall-cmd >/dev/null 2>&1; then
    for port in 6443/tcp 2379/tcp 2380/tcp 5001/tcp 8472/udp 10250/tcp 51820/udp 51821/udp; do
        firewall-cmd --permanent --add-port="$port"
    done
    for src in 10.42.0.0/16 10.43.0.0/16; do
        firewall-cmd --permanent --zone=trusted --add-source="$src"
    done
    firewall-cmd --reload
elif command -v ufw >/dev/null 2>&1; then
    ufw allow from 10.42.0.0/16
    ufw allow from 10.43.0.0/16
    ufw allow 8472/udp
    ufw allow 51820/udp
    ufw allow 6443/tcp
    ufw allow 10250/tcp
    ufw allow 2379/tcp
    ufw allow 2380/tcp
    ufw allow 443/tcp
fi

# ---- pciutils (AMD GPU detection at join time) -------------------------------
if command -v dnf >/dev/null 2>&1; then
    dnf install -y pciutils
else
    apt-get install -y pciutils
fi

# ---- kubectl group (kubeconfig is 0640 kubectl-group) ------------------------
groupadd -f kubectl
mkdir -p /etc/rancher/k3s
chgrp -R kubectl /etc/rancher/k3s
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    usermod -aG kubectl "$SUDO_USER"
fi

echo "k3s-node-prep: done."
