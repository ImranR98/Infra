#!/bin/bash
# lib/net.sh — networking utilities

get_node_ip() {
    local iface
    iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    [ -n "$iface" ] || return 1
    ip -4 addr show "$iface" | grep -oP 'inet \K[\d.]+'
}

configure_k3s_firewall() {
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=6443/tcp #apiserver
        firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16 #pods
        firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16 #services
        firewall-cmd --permanent --add-port=2379/tcp #etcd
        firewall-cmd --permanent --add-port=2380/tcp #etcd
        firewall-cmd --permanent --add-port=8472/udp #flannel-vxlan
        firewall-cmd --permanent --add-port=10250/tcp #metrics
        firewall-cmd --permanent --add-port=51820/udp #flannel-wg
        firewall-cmd --permanent --add-port=51821/udp #flannel-wg
        firewall-cmd --reload
        echo "Firewall configured (firewalld)."
    elif command -v ufw >/dev/null 2>&1; then
        ufw allow from 10.42.0.0/16 2>/dev/null || true   # pod network CIDR
        ufw allow from 10.43.0.0/16 2>/dev/null || true   # service CIDR
        ufw allow 8472/udp 2>/dev/null || true            # Flannel VXLAN overlay
        ufw allow 51820/udp 2>/dev/null || true           # Flannel WireGuard backend
        ufw allow 6443/tcp 2>/dev/null || true            # K3s API server
        ufw allow 10250/tcp 2>/dev/null || true           # kubelet API
        ufw allow 2379/tcp 2>/dev/null || true            # etcd client
        ufw allow 2380/tcp 2>/dev/null || true            # etcd peer
        ufw allow 443/tcp 2>/dev/null || true             # HTTPS ingress
        echo "Firewall configured (ufw)."
    else
        echo "Warning: neither firewall-cmd nor ufw found. Skipping firewall configuration."
        echo "If using a different firewall, ensure:"
        echo "  - Pod CIDR 10.42.0.0/16 and Service CIDR 10.43.0.0/16 are trusted"
        echo "  - Ports 8472/udp, 51820/udp, 6443/tcp, 10250/tcp, 2379-2380/tcp, 443/tcp are open"
    fi
}
