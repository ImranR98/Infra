#!/bin/bash
# DESC: Install WireGuard and deploy a config file
set -euo pipefail
source "$INFRA_ROOT/lib/common.sh"

CONFIG_FILE="${1:?Usage: $0 <path-to-wireguard-conf>}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: config file not found: $CONFIG_FILE" >&2
    exit 1
fi

SU=$(get_sudo_cmd)

if ! command -v wg >/dev/null 2>&1; then
    PKG_MGR=$(detect_pkgmgr)
    echo "Installing wireguard-tools..."
    install_pkgs "$SU" "$PKG_MGR" wireguard-tools || {
        echo "Error: failed to install wireguard-tools" >&2
        exit 1
    }
fi

$SU bash -c 'mkdir -p /etc/wireguard'
$SU bash -c 'cp "$1" "$2"' _ "$CONFIG_FILE" /etc/wireguard/wg0.conf
$SU bash -c 'chmod 600 /etc/wireguard/wg0.conf'

# Split-/1 AllowedIPs are less specific than local routes, protecting K3s/LAN.
$SU bash -c "sed -i 's/^AllowedIPs\s*=.*/AllowedIPs = 0.0.0.0\/1, 128.0.0.0\/1/' /etc/wireguard/wg0.conf"

# Endpoint inside /1 causes handshake to loop into wg0; PostUp /32 route forces it via physical gateway.
ENDPOINT=$($SU bash -c "grep -oP '^Endpoint\s*=\s*\K[\d.]+' /etc/wireguard/wg0.conf")
GATEWAY=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
if [ -n "$ENDPOINT" ] && [ -n "$GATEWAY" ]; then
    $SU bash -c 'sed -i "$1" "$2"' _ "/^\[Interface\]/a\PostUp = ip route add $ENDPOINT/32 via $GATEWAY" /etc/wireguard/wg0.conf
    $SU bash -c 'sed -i "$1" "$2"' _ "/^\[Interface\]/a\PreDown = ip route delete $ENDPOINT/32 via $GATEWAY || true" /etc/wireguard/wg0.conf

    # Drop Table=auto (inserted for split-/1).  PostUp/PreDown /32 routes
    # avoid dead loop; main-table routes coexist with K3s.
    $SU bash -c "sed -i '/^Table\s*=/d' /etc/wireguard/wg0.conf"
fi

echo "AllowedIPs pinned to 0.0.0.0/1, 128.0.0.0/1 to protect K3s subnets from the VPN."
echo "Config deployed to /etc/wireguard/wg0.conf"

# Add restart resilience with stale-interface guard — handles suspend/resume
$SU bash -c 'mkdir -p /etc/systemd/system/wg-quick@wg0.service.d'
$SU bash -c 'tee /etc/systemd/system/wg-quick@wg0.service.d/restart.conf >/dev/null' <<EOF
[Service]
Restart=on-failure
RestartSec=15
ExecStartPre=-ip link delete wg0 2>/dev/null
EOF
$SU bash -c 'systemctl daemon-reload' 2>/dev/null || true

$SU bash -c 'systemctl enable wg-quick@wg0' 2>/dev/null || true
$SU bash -c 'systemctl restart wg-quick@wg0'
echo "WireGuard interface wg0 started and enabled."
