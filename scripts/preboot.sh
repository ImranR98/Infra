#!/bin/bash
# DESC: Install the preboot initramfs LUKS-unlock module (dracut-remote-luks-unlock).
# frpc: initramfs frpc tunnels SSH via FRPS (mTLS certs from
# secrets/<hostname>/frpc/, PROXY_HOST/TLS_SERVER_NAME from secrets/VARS.<hostname>.env,
# PROXY_IP resolved here). crypt-ssh: dropbear SSH directly on the LAN, patched
# to the preboot port (ethernet only). Re-run frpc after rotating the preboot
# mTLS certs. Run ON the node.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"

usage() {
    echo "Usage: $(basename "$0") <frpc|crypt-ssh>   (run ON the node)"
    echo
    echo "  frpc       initramfs frpc tunnels SSH via FRPS (needs the rendered mTLS"
    echo "             certs and the compose env — see DESC header)"
    echo "  crypt-ssh  dropbear SSH directly on the LAN (ethernet only)"
    exit 1
}

module="${1:-}"
case "$module" in
    frpc | crypt-ssh) ;;
    *) usage ;;
esac

target="$(hostname)"
work_dir=/tmp/dracut-remote-luks-unlock

# LUKS check — silently skip machines without an encrypted root.
root_src=$(findmnt -n -o SOURCE /sysroot 2>/dev/null | sed 's/\[.*//')
[ -n "$root_src" ] || root_src=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/\[.*//')
if ! { [ -n "$root_src" ] && [ -b "$root_src" ] && lsblk -s -o TYPE "$root_src" | grep -q crypt; }; then
    echo "Root partition is not LUKS-encrypted — nothing to do. Re-run after adding LUKS."
    exit 0
fi

rm -rf "$work_dir"
git clone --depth 1 https://github.com/ImranR98/dracut-remote-luks-unlock.git "$work_dir"

setup_args=(bash "$work_dir/setup.sh" --user "$(id -un)")

if [ "$module" = frpc ]; then
    env_file="$INFRA_ROOT/secrets/VARS.$target.env"
    [ -f "$env_file" ] || { echo "Error: $env_file not found" >&2; exit 1; }
    proxy_host=$(grep -E '^PROXY_HOST=' "$env_file" | head -1 | cut -d= -f2- | tr -d '"'"'"' ')
    tls_server_name=$(grep -E '^TLS_SERVER_NAME=' "$env_file" | head -1 | cut -d= -f2- | tr -d '"'"'"' ')
    [ -n "$proxy_host" ] && [ -n "$tls_server_name" ] || {
        echo "Error: PROXY_HOST and TLS_SERVER_NAME must be set in $env_file" >&2
        exit 1
    }
    proxy_ip=$(getent hosts "$proxy_host" | awk '{print $1; exit}')
    [ -n "$proxy_ip" ] || { echo "Error: cannot resolve PROXY_HOST '$proxy_host'" >&2; exit 1; }

    certs_dir="$INFRA_ROOT/secrets/$target/frpc"
    for f in ca.crt preboot-client.crt preboot-client.key; do
        [ -f "$certs_dir/$f" ] || { echo "Error: $certs_dir/$f not found" >&2; exit 1; }
    done

    cat >"$work_dir/frpc-preboot.toml" <<EOF
serverAddr = "$proxy_ip"
serverPort = 7000
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]
loginFailExit = true

transport.tls.enable = true
transport.tls.serverName = "$tls_server_name"
transport.tls.certFile = "/etc/frp/client.crt"
transport.tls.keyFile = "/etc/frp/client.key"
transport.tls.trustedCaFile = "/etc/frp/ca.crt"

[[proxies]]
name = "ssh-preboot"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 8887
EOF

    setup_args+=(--frpc-config "$work_dir/frpc-preboot.toml"
        --frpc-cert "$certs_dir/preboot-client.crt"
        --frpc-key "$certs_dir/preboot-client.key"
        --frpc-ca "$certs_dir/ca.crt")
else
    sed -i 's/^dropbear_port="22"/dropbear_port="8887"/' "$work_dir/modules/99crypt-ssh/crypt-ssh.conf"
fi

sudo "${setup_args[@]}"
rm -rf "$work_dir"

echo "Preboot $module installed — on the next boot, LUKS unlock runs before root is mounted."
