#!/bin/bash
# DESC: Deploy a WireGuard client config from an existing wg0.conf (e.g. a VPN
# provider's). AllowedIPs are rewritten to split-/1 routes (less specific than
# LAN/K3s routes, so local traffic stays direct) and a /32 route for the
# endpoint via the physical gateway avoids a dead loop (the endpoint lives
# inside the /1). Keys are never echoed. Run ON the machine.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"

usage() {
    echo "Usage: $(basename "$0") <path/to/wg0.conf>   (run ON the machine)"
    exit 1
}

conf_src="${1:-}"
[ -n "$conf_src" ] || usage
[ -f "$conf_src" ] || { echo "Error: $conf_src not found" >&2; exit 1; }

# get <Key> — first value of an INI key; keys are parsed in-memory, never echoed.
get() { grep -E "^$1[[:space:]]*=" "$conf_src" | head -1 | sed 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//'; }

private_key=$(get PrivateKey)
addresses=$(grep -E '^Address[[:space:]]*=' "$conf_src" | sed 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//' | paste -sd, -)
dns=$(get DNS)
mtu=$(get MTU)
fwmark=$(get FwMark)
peer_public_key=$(get PublicKey)
peer_preshared_key=$(get PresharedKey)
keepalive=$(get PersistentKeepalive)
endpoint=$(get Endpoint)
endpoint_ip=$(grep -oE '^Endpoint[[:space:]]*=[[:space:]]*[0-9]+(\.[0-9]+){3}' "$conf_src" | grep -oE '[0-9]+(\.[0-9]+){3}' | head -1)
gateway=$(ip route show default 2>/dev/null | awk '{print $3; exit}')

[ -n "$private_key" ] && [ -n "$peer_public_key" ] && [ -n "$endpoint" ] ||
    { echo "Error: wg0.conf must contain PrivateKey, PublicKey and Endpoint" >&2; exit 1; }

if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y wireguard-tools
else
    sudo apt-get update -y
    sudo apt-get install -y wireguard-tools
fi

sudo install -d -m 700 /etc/wireguard
tmp_conf=$(mktemp)
{
    echo "[Interface]"
    echo "PrivateKey = $private_key"
    echo "Address = $addresses"
    [ -n "$dns" ] && echo "DNS = $dns"
    [ -n "$mtu" ] && echo "MTU = $mtu"
    [ -n "$fwmark" ] && echo "FwMark = $fwmark"
    if [ -n "$endpoint_ip" ] && [ -n "$gateway" ]; then
        echo "PostUp = ip route add $endpoint_ip/32 via $gateway"
        echo "PreDown = ip route delete $endpoint_ip/32 via $gateway || true"
    fi
    echo
    echo "[Peer]"
    echo "PublicKey = $peer_public_key"
    [ -n "$peer_preshared_key" ] && echo "PresharedKey = $peer_preshared_key"
    echo "AllowedIPs = 0.0.0.0/1, 128.0.0.0/1"
    echo "Endpoint = $endpoint"
    [ -n "$keepalive" ] && echo "PersistentKeepalive = $keepalive"
} >"$tmp_conf"
sudo install -m 600 "$tmp_conf" /etc/wireguard/wg0.conf
rm -f "$tmp_conf"

sudo systemctl enable --now wg-quick@wg0
echo "wireguard: deployed (wg-quick@wg0)."
