#!/bin/bash
# DESC: Prepare a K3s node: sysctls, firewall
# ports/trusted CIDRs. Runs ON the node as root
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
# Open every port the stack needs explicitly, so this works regardless of the
# zone's default range (FedoraWorkstation ships 1025-65535 open; minimal
# installs don't): 80/443 Traefik, 6443 apiserver, 2379/2380 etcd,
# 5001 k3s embedded registry, 8472 flannel VXLAN, 51820/51821 flannel-wireguard.
# etcd stays open deliberately: it is mTLS-authenticated and a future second
# server would need it between control-plane IPs. 10250 stays open because
# clustered Alloy may scrape a node's kubelet from another node, and that
# cross-node pod traffic is SNAT'd to the peer's LAN IP (pod-CIDR trust does
# not apply); kubelet requires auth, so anonymous LAN access is a 401.
# 9100 stays dropped: node-exporter is unauthenticated and Alloy scrapes it on
# the pod network. Loopback bypasses firewalld and the pod CIDRs are in the
# trusted zone, so the plain drop is safe (no source allowlist needed).
# priority=-10 keeps it in the zone's _pre chain, ahead of any open range.
if command -v firewall-cmd >/dev/null 2>&1; then
    zone="$(firewall-cmd --get-default-zone)"
    for port in 80/tcp 443/tcp 6443/tcp 2379/tcp 2380/tcp 5001/tcp 8472/udp 51820/udp 51821/udp 10250/tcp; do
        firewall-cmd --permanent --add-port="$port" >/dev/null
    done
    for src in 10.42.0.0/16 10.43.0.0/16; do
        firewall-cmd --permanent --zone=trusted --add-source="$src" >/dev/null
    done
    rule="rule priority=-10 family=ipv4 port port=9100 protocol=tcp drop"
    firewall-cmd --permanent --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1 ||
        firewall-cmd --permanent --zone="$zone" --add-rich-rule="$rule" >/dev/null
    firewall-cmd --reload
elif command -v ufw >/dev/null 2>&1; then
    ufw allow from 10.42.0.0/16
    ufw allow from 10.43.0.0/16
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 6443/tcp
    ufw allow 2379/tcp
    ufw allow 2380/tcp
    ufw allow 5001/tcp
    ufw allow 8472/udp
    ufw allow 51820/udp
    ufw allow 51821/udp
    ufw allow 10250/tcp
    ufw deny 9100/tcp
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

# ---- K3s config dir ----------------------------------------------------------
mkdir -p /etc/rancher/k3s

echo "k3s-node-prep: done."
