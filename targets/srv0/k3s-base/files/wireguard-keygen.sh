#!/bin/bash
# DESC: Generate the WireGuard server + client keys on the wireguard-pvc if
# they do not exist yet. Runs as an init container before the server starts;
# idempotent and never prints key material. Client profiles are fetched on an
# unlocked host with scripts/wg-client.sh.
set -euo pipefail

WG_DIR=/wg
WG_ENDPOINT="${WG_ENDPOINT:-}"
WG_SUBNET=10.100.0
WG_PORT=51830
WG_MTU=1280

[ -n "$WG_ENDPOINT" ] || { echo "Error: WG_ENDPOINT is required (public host:port clients dial)" >&2; exit 1; }

read -r -a clients <<<"${WG_CLIENTS:-client1 client2}"
[ "${#clients[@]}" -gt 0 ] || { echo "Error: WG_CLIENTS is empty" >&2; exit 1; }

umask 077
mkdir -p "$WG_DIR"

# Never regenerate existing keys; a missing client profile can't be recovered,
# so warn only.
if [ -s "$WG_DIR/wg0.conf" ]; then
    for client in "${clients[@]}"; do
        [ -s "$WG_DIR/$client.conf" ] ||
            echo "Warning: /wg/$client.conf is missing; to regenerate all keys, delete /wg/wg0.conf and restart the pod" >&2
    done
    echo "wireguard-keygen: keys already present"
    exit 0
fi

echo "wireguard-keygen: generating server and client keys"

wg genkey >"$WG_DIR/server.key"
wg pubkey <"$WG_DIR/server.key" >"$WG_DIR/server.pub"
server_pub="$(<"$WG_DIR/server.pub")"

{
    printf '[Interface]\n'
    printf 'PrivateKey = %s\n' "$(<"$WG_DIR/server.key")"
    printf 'Address = %s.1/24\n' "$WG_SUBNET"
    printf 'ListenPort = %s\n' "$WG_PORT"
    printf 'MTU = %s\n' "$WG_MTU"
} >"$WG_DIR/wg0.conf"

i=0
for client in "${clients[@]}"; do
    i=$((i + 1))
    addr="$WG_SUBNET.$((i + 1))"

    wg genkey >"$WG_DIR/$client.key"
    wg pubkey <"$WG_DIR/$client.key" >"$WG_DIR/$client.pub"
    wg genpsk >"$WG_DIR/$client.psk"

    {
        printf '\n[Peer]\n'
        printf '# %s\n' "$client"
        printf 'PublicKey = %s\n' "$(<"$WG_DIR/$client.pub")"
        printf 'PresharedKey = %s\n' "$(<"$WG_DIR/$client.psk")"
        printf 'AllowedIPs = %s/32\n' "$addr"
    } >>"$WG_DIR/wg0.conf"

    {
        printf '[Interface]\n'
        printf 'PrivateKey = %s\n' "$(<"$WG_DIR/$client.key")"
        printf 'Address = %s/32\n' "$addr"
        printf 'DNS = %s.1\n' "$WG_SUBNET"
        printf 'MTU = %s\n' "$WG_MTU"
        printf '\n[Peer]\n'
        printf 'PublicKey = %s\n' "$server_pub"
        printf 'PresharedKey = %s\n' "$(<"$WG_DIR/$client.psk")"
        printf 'Endpoint = %s\n' "$WG_ENDPOINT"
        printf 'AllowedIPs = 0.0.0.0/0\n'
        printf 'PersistentKeepalive = 25\n'
    } >"$WG_DIR/$client.conf"

    echo "wireguard-keygen: created /wg/$client.conf (address $addr)"
done

chmod 700 "$WG_DIR"
chmod 600 "$WG_DIR"/*.key "$WG_DIR"/*.psk "$WG_DIR"/*.conf "$WG_DIR"/server.pub 2>/dev/null || true
echo "wireguard-keygen: done"
