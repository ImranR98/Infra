#!/bin/bash
# DESC: Prepare a K3s node: sysctls, firewall
# ports/trusted CIDRs, pciutils. Runs ON the node as root
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

# ---- firewall (K3s ports + pod/service CIDRs + LAN exposure) -----------------
# The FedoraWorkstation default zone ships 1025-65535 open. Keep the range
# (desktop apps rely on it) but drop the cluster-internal ports from the LAN:
#   9100   node-exporter   (unauthenticated; scraped by Alloy pods)
#   10250  kubelet         (apiserver reaches kubelets via loopback/pod net)
# etcd (2379/2380) stays open deliberately: it is mTLS-authenticated and a
# future second server would need it between control-plane IPs.
# Loopback bypasses firewalld and the pod CIDRs are in the trusted zone, so
# plain drops are safe (no source allowlist needed). priority=-10 keeps the
# drop in the zone's _pre chain, ahead of the open 1025-65535 ports.
if command -v firewall-cmd >/dev/null 2>&1; then
    zone="$(firewall-cmd --get-default-zone)"
    for port in 6443/tcp 2379/tcp 2380/tcp 5001/tcp 8472/udp 51820/udp 51821/udp; do
        firewall-cmd --permanent --add-port="$port" >/dev/null
    done
    # 10250 was opened individually before; the drop rule replaces it.
    firewall-cmd --permanent --zone="$zone" --remove-port=10250/tcp >/dev/null 2>&1 || true
    for src in 10.42.0.0/16 10.43.0.0/16; do
        firewall-cmd --permanent --zone=trusted --add-source="$src" >/dev/null
    done
    for port in 9100 10250; do
        rule="rule priority=-10 family=ipv4 port port=$port protocol=tcp drop"
        firewall-cmd --permanent --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1 ||
            firewall-cmd --permanent --zone="$zone" --add-rich-rule="$rule" >/dev/null
    done
    firewall-cmd --reload
elif command -v ufw >/dev/null 2>&1; then
    ufw allow from 10.42.0.0/16
    ufw allow from 10.43.0.0/16
    ufw allow 8472/udp
    ufw allow 51820/udp
    ufw allow 6443/tcp
    ufw allow 443/tcp
    ufw deny 9100/tcp
    ufw deny 10250/tcp
fi

# ---- control-plane I/O protection (server nodes only) ------------------------
# etcd/apiserver/kubelet run in system.slice; pods run in kubepods.slice. A low
# IOWeight on the pod slice gives the control plane a 10:1 I/O priority
# advantage, so a pod burst (backup, image pull, migration) cannot stall etcd.
# Agents don't run etcd, so this is server-only.
role="${K3S_ROLE:-${K3S_JOIN_ROLE:-}}"
if [ -z "$role" ] && { [ -d /var/lib/rancher/k3s/server ] || systemctl is-active --quiet k3s; }; then
    role=server
fi
if [ "$role" = server ]; then
    install -d -m 755 /etc/systemd/system/kubepods.slice.d
    cat >/etc/systemd/system/kubepods.slice.d/io.conf <<'EOF'
[Slice]
IOAccounting=true
IOWeight=10
EOF
    systemctl daemon-reload
    systemctl set-property --runtime kubepods.slice IOAccounting=true IOWeight=10 2>/dev/null || true
    echo "k3s-node-prep: control-plane I/O protection applied (kubepods.slice IOWeight=10)"
fi

# ---- pciutils (AMD GPU detection at join time) -------------------------------
if command -v dnf >/dev/null 2>&1; then
    dnf install -y pciutils
else
    apt-get install -y pciutils
fi

# ---- K3s config dir ----------------------------------------------------------
mkdir -p /etc/rancher/k3s

echo "k3s-node-prep: done."
