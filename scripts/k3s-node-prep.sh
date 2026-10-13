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

[ "$(id -u)" -eq 0 ] || { echo "Error: must run as root (sudo $0)" >&2; exit 1; }

# ---- sysctls ----------------------------------------------------------------
cat >/etc/sysctl.d/90-k3s.conf <<'EOF'
# K3s node tuning — applied by scripts/k3s-node-prep.sh
fs.inotify.max_user_watches = 6000000
fs.inotify.max_user_instances = 512
user.max_user_namespaces = 28633

# Bound dirty writeback so a burst writer (backup/image pull) cannot queue
# gigabytes behind etcd's fsyncs — a shallow queue keeps commit latency bounded.
# 64M/16M, not 256M/64M: a slow root device shows fsync stalls of 50-290ms
# once bursts queue, and etcd's commit latency scales with the queued depth.
vm.dirty_bytes = 67108864
vm.dirty_background_bytes = 16777216
EOF
sysctl --system >/dev/null

# Longhorn attaches volumes via the host iSCSI initiator (open-iscsi/
# iscsi-initiator-utils come from prereqs.sh).
systemctl enable --now iscsid

# ---- firewall (K3s ports + LAN exposure) --------------------------------------
# Open every port the stack needs explicitly, so this works regardless of the
# zone's default range (FedoraWorkstation ships 1025-65535 open; minimal
# installs don't): 80/443 Traefik, 6443 apiserver, 2379/2380 etcd,
# 5001 k3s embedded registry, 8472 flannel VXLAN, 51820/51821 flannel-wireguard.
# etcd stays open deliberately: it is mTLS-authenticated and a future second
# server would need it between control-plane IPs. 10250 stays open because
# clustered Alloy may scrape a node's kubelet from another node, and that
# cross-node pod traffic is SNAT'd to the peer's LAN IP (pod-CIDR trust does
# not apply); kubelet requires auth, so anonymous LAN access is a 401.
# The pod/service CIDRs are deliberately NOT trusted: a compromised pod must
# not be able to reach arbitrary host listeners (apps-namespace egress policies
# close the pod-to-LAN path at the CNI). The one exception is 9100 below.
# 9100 stays dropped for everything except the pod CIDR: node-exporter is
# unauthenticated and Alloy scrapes it on the pod network; the accept rule
# (priority=-11, before the drop) keeps that working now that pods are no
# longer trusted wholesale.
# The VPN subnet keeps trust: wg0 appears at runtime, so firewalld never binds
# it to a zone, and VPN clients are LAN clients by design.
if command -v firewall-cmd >/dev/null 2>&1; then
    zone="$(firewall-cmd --get-default-zone)"
    for port in 80/tcp 443/tcp 6443/tcp 2379/tcp 2380/tcp 5001/tcp 8472/udp 51820/udp 51821/udp 10250/tcp; do
        firewall-cmd --permanent --add-port="$port" >/dev/null
    done
    firewall-cmd --permanent --zone=trusted --add-source=10.100.0.0/24 >/dev/null
    allow_9100="rule priority=-11 family=ipv4 source address=10.42.0.0/16 port port=9100 protocol=tcp accept"
    firewall-cmd --permanent --zone="$zone" --query-rich-rule="$allow_9100" >/dev/null 2>&1 ||
        firewall-cmd --permanent --zone="$zone" --add-rich-rule="$allow_9100" >/dev/null
    rule="rule priority=-10 family=ipv4 port port=9100 protocol=tcp drop"
    firewall-cmd --permanent --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1 ||
        firewall-cmd --permanent --zone="$zone" --add-rich-rule="$rule" >/dev/null
    firewall-cmd --reload
elif command -v ufw >/dev/null 2>&1; then
    ufw allow from 10.100.0.0/24
    ufw allow from 10.42.0.0/16 to any port 9100 proto tcp
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
# etcd/apiserver/kubelet run in system.slice; pods run in kubepods.slice. The
# pod slice's IOWeight only binds on an elevator that honors weights (BFQ);
# where the device runs `none` it is inert (this node's NVMe does), but it is
# applied for the nodes/devices where it does bind. Agents don't run etcd, so
# this is server-only.
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
    # A weekly fstrim of the LUKS root can stall etcd's fdatasyncs for seconds;
    # idle CPU priority keeps the trim from starving the control plane (the
    # idle I/O class is inert while the device elevator is `none`).
    install -d -m 755 /etc/systemd/system/fstrim.service.d
    cat >/etc/systemd/system/fstrim.service.d/io-priority.conf <<'EOF'
[Service]
Nice=19
IOSchedulingClass=idle
EOF
    systemctl daemon-reload
    systemctl set-property --runtime kubepods.slice IOAccounting=true IOWeight=10 2>/dev/null || true
    echo "k3s-node-prep: control-plane I/O protection applied (kubepods.slice IOWeight=10, fstrim idle priority)"
fi

# ---- K3s config dir ----------------------------------------------------------
mkdir -p /etc/rancher/k3s

echo "k3s-node-prep: done."
