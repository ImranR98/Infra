#!/bin/bash
# DESC: Generate the AmneziaWG server + client keys and obfuscation parameters
# on the remote-access-amneziawg-pvc if they do not exist yet. Runs as an init
# container before the server starts; idempotent and never prints key material.
# Client profiles are fetched on an unlocked host with
# scripts/remote-access-client.sh.
set -euo pipefail

WG_DIR=/wg
WG_ENDPOINT="${REMOTE_ACCESS_AMNEZIAWG_ENDPOINT:-}"
WG_SUBNET=10.100.0
WG_PORT=51830
# Must fit inside the public-exposure tunnel's 1340-byte MTU once the AWG
# obfuscation/padding overhead is added.
WG_MTU=1180

[ -n "$WG_ENDPOINT" ] || { echo "Error: REMOTE_ACCESS_AMNEZIAWG_ENDPOINT is required (public host:port clients dial)" >&2; exit 1; }

read -r -a clients <<<"${REMOTE_ACCESS_AMNEZIAWG_CLIENTS:-client1 client2}"
[ "${#clients[@]}" -gt 0 ] || { echo "Error: REMOTE_ACCESS_AMNEZIAWG_CLIENTS is empty" >&2; exit 1; }

umask 077
mkdir -p "$WG_DIR"

# Never regenerate existing keys; a missing client profile can't be recovered,
# so warn only.
if [ -s "$WG_DIR/ra-amneziawg0.conf" ]; then
    for client in "${clients[@]}"; do
        [ -s "$WG_DIR/$client.conf" ] ||
            echo "Warning: /wg/$client.conf is missing; to regenerate all keys, delete /wg/ra-amneziawg0.conf and restart the pod" >&2
    done
    echo "ra-amneziawg-keygen: keys already present"
    exit 0
fi

echo "ra-amneziawg-keygen: generating server and client keys"

rand() { # rand MIN MAX (inclusive)
    local min=$1 max=$2
    echo $((min + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % (max - min + 1)))
}

# One obfuscation set shared by the server and every client: S1-S4 and H1-H4
# must match on both sides, and S1-S4 >= 12 is required by header protection.
s1=$(rand 20 100); s2=$(rand 20 100); while [ "$s2" = "$s1" ]; do s2=$(rand 20 100); done
s3=$(rand 20 100); while [ "$s3" = "$s1" ] || [ "$s3" = "$s2" ]; do s3=$(rand 20 100); done
s4=$(rand 20 100); while [ "$s4" = "$s1" ] || [ "$s4" = "$s2" ] || [ "$s4" = "$s3" ]; do s4=$(rand 20 100); done
h1=$(rand 100000 999999); h2=$(rand 100000 999999); while [ "$h2" = "$h1" ]; do h2=$(rand 100000 999999); done
h3=$(rand 100000 999999); while [ "$h3" = "$h1" ] || [ "$h3" = "$h2" ]; do h3=$(rand 100000 999999); done
h4=$(rand 100000 999999); while [ "$h4" = "$h1" ] || [ "$h4" = "$h2" ] || [ "$h4" = "$h3" ]; do h4=$(rand 100000 999999); done

awg genkey >"$WG_DIR/server.key"
awg pubkey <"$WG_DIR/server.key" >"$WG_DIR/server.pub"
awg genkey >"$WG_DIR/server.hpk"
server_pub="$(<"$WG_DIR/server.pub")"
header_protection_key="$(<"$WG_DIR/server.hpk")"

{
    printf '[Interface]\n'
    printf 'PrivateKey = %s\n' "$(<"$WG_DIR/server.key")"
    printf 'Address = %s.1/24\n' "$WG_SUBNET"
    printf 'ListenPort = %s\n' "$WG_PORT"
    printf 'MTU = %s\n' "$WG_MTU"
    printf 'S1 = %s\nS2 = %s\nS3 = %s\nS4 = %s\n' "$s1" "$s2" "$s3" "$s4"
    printf 'H1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' "$h1" "$h2" "$h3" "$h4"
    printf 'HeaderProtectionKey = %s\n' "$header_protection_key"
    printf 'ContentPaddingAddition = 0-64\n'
} >"$WG_DIR/ra-amneziawg0.conf"

i=0
for client in "${clients[@]}"; do
    i=$((i + 1))
    addr="$WG_SUBNET.$((i + 1))"

    awg genkey >"$WG_DIR/$client.key"
    awg pubkey <"$WG_DIR/$client.key" >"$WG_DIR/$client.pub"
    awg genpsk >"$WG_DIR/$client.psk"

    {
        printf '\n[Peer]\n'
        printf '# %s\n' "$client"
        printf 'PublicKey = %s\n' "$(<"$WG_DIR/$client.pub")"
        printf 'PresharedKey = %s\n' "$(<"$WG_DIR/$client.psk")"
        printf 'AllowedIPs = %s/32\n' "$addr"
    } >>"$WG_DIR/ra-amneziawg0.conf"

    {
        printf '[Interface]\n'
        printf 'PrivateKey = %s\n' "$(<"$WG_DIR/$client.key")"
        printf 'Address = %s/32\n' "$addr"
        printf 'DNS = %s.1\n' "$WG_SUBNET"
        printf 'MTU = %s\n' "$WG_MTU"
        printf 'Jc = 4\nJmin = 40\nJmax = 70\n'
        printf 'S1 = %s\nS2 = %s\nS3 = %s\nS4 = %s\n' "$s1" "$s2" "$s3" "$s4"
        printf 'H1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' "$h1" "$h2" "$h3" "$h4"
        printf 'HeaderProtectionKey = %s\n' "$header_protection_key"
        printf 'ContentPaddingAddition = 0-64\n'
        printf 'I1 = <b 0x160301><r 64>\n'
        printf 'I2 = <rd 32>\n'
        printf 'I3 = <rc 64>\n'
        printf 'I4 = <t>\n'
        printf 'I5 = <r 128>\n'
        printf '\n[Peer]\n'
        printf 'PublicKey = %s\n' "$server_pub"
        printf 'PresharedKey = %s\n' "$(<"$WG_DIR/$client.psk")"
        printf 'Endpoint = %s\n' "$WG_ENDPOINT"
        printf 'AllowedIPs = 0.0.0.0/0\n'
        printf 'PersistentKeepalive = 25\n'
    } >"$WG_DIR/$client.conf"

    echo "ra-amneziawg-keygen: created /wg/$client.conf (address $addr)"
done

chmod 700 "$WG_DIR"
chmod 600 "$WG_DIR"/*.key "$WG_DIR"/*.psk "$WG_DIR"/*.conf "$WG_DIR"/*.hpk "$WG_DIR"/server.pub 2>/dev/null || true
echo "ra-amneziawg-keygen: done"
