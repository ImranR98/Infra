#!/bin/bash
# DESC: Install WireGuard and deploy a config file
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"

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

# Rewrite AllowedIPs.  0.0.0.0/1 + 128.0.0.0/1 covers all IPv4
# but is less specific than directly-connected routes (/24), so
# K3s (10.42.0.0/16, 10.43.0.0/16) and the LAN subnet stay on
# the physical NIC.
$SU bash -c "sed -i 's/^AllowedIPs\s*=.*/AllowedIPs = 0.0.0.0\/1, 128.0.0.0\/1/' /etc/wireguard/wg0.conf"

# The endpoint falls inside 0.0.0.0/1, which causes a dead loop:
# WireGuard's own handshake packets get routed into wg0 instead of
# out the physical NIC.  Add a PostUp rule so the endpoint always
# goes through the physical gateway.
ENDPOINT=$($SU bash -c "grep -oP '^Endpoint\s*=\s*\K[\d.]+' /etc/wireguard/wg0.conf")
GATEWAY=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
if [ -n "$ENDPOINT" ] && [ -n "$GATEWAY" ]; then
	$SU bash -c 'sed -i "$1" "$2"' _ "/^\[Interface\]/a\PostUp = ip route add $ENDPOINT/32 via $GATEWAY" /etc/wireguard/wg0.conf
	$SU bash -c 'sed -i "$1" "$2"' _ "/^\[Interface\]/a\PreDown = ip route delete $ENDPOINT/32 via $GATEWAY" /etc/wireguard/wg0.conf

	# Remove default route left by AllowedIPs rewrite (wireguard-tools adds it,
	# but the PostUp rules handle the split tunnel)
	$SU bash -c "sed -i '/^Table\s*=/d' /etc/wireguard/wg0.conf"
fi

echo "AllowedIPs pinned to 0.0.0.0/1, 128.0.0.0/1 to protect K3s subnets from the VPN."
echo "Config deployed to /etc/wireguard/wg0.conf"

# Ensure wg-quick starts before K3s so the VPN is fully up
# before pods begin DNS resolution and network setup
$SU bash -c 'mkdir -p /etc/systemd/system/wg-quick@wg0.service.d'
$SU bash -c 'tee /etc/systemd/system/wg-quick@wg0.service.d/order-before-k3s.conf >/dev/null' <<EOF
[Unit]
Before=k3s.service
EOF
$SU bash -c 'systemctl daemon-reload' 2>/dev/null || true

$SU bash -c 'systemctl enable wg-quick@wg0' 2>/dev/null || true
$SU bash -c 'systemctl restart wg-quick@wg0'
echo "WireGuard interface wg0 started and enabled."
