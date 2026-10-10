#!/bin/bash
# DESC: Install the preboot initramfs LUKS-unlock module (dracut-remote-luks-unlock).
# public-exposure: initramfs WireGuard client (pubexp-pre0) handshakes with the
# vps0 hub so dropbear can be reached over the tunnel; keys come from
# config/<hostname>/public-exposure/ and PUBLIC_EXPOSURE_HOST/PORT from
# config/<hostname>/compose.env (resolved here). crypt-ssh: dropbear SSH directly
# on the LAN, patched to the preboot port (ethernet only). Run ON the node.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"

usage() {
    echo "Usage: $(basename "$0") <public-exposure|crypt-ssh>   (run ON the node)"
    echo
    echo "  public-exposure  initramfs WireGuard client to the vps0 hub (needs the"
    echo "                   keys from config/<hostname>/public-exposure/ and the"
    echo "                   compose env — see DESC header)"
    echo "  crypt-ssh        dropbear SSH directly on the LAN (ethernet only)"
    echo
    echo "Env overrides (testing a branch before it is pushed):"
    echo "  PREBOOT_REPO=<url|path>  default: the GitHub repo"
    echo "  PREBOOT_REF=<branch>     optional clone branch"
    exit 1
}

module="${1:-}"
case "$module" in
    public-exposure | crypt-ssh) ;;
    *) usage ;;
esac

target="$(hostname)"
work_dir=/tmp/dracut-remote-luks-unlock

# LUKS check — silently skip machines without an encrypted root. The /sysroot
# mount only exists in some environments; findmnt's non-zero exit must not kill
# the script under set -e (|| true).
root_src=$(findmnt -n -o SOURCE /sysroot 2>/dev/null | sed 's/\[.*//' || true)
[ -n "$root_src" ] || root_src=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/\[.*//' || true)
if ! { [ -n "$root_src" ] && [ -b "$root_src" ] && lsblk -s -o TYPE "$root_src" | grep -q crypt; }; then
    echo "Root partition is not LUKS-encrypted — nothing to do. Re-run after adding LUKS."
    exit 0
fi

rm -rf "$work_dir"
repo_url="${PREBOOT_REPO:-https://github.com/ImranR98/dracut-remote-luks-unlock.git}"
clone_args=(--depth 1)
[ -n "${PREBOOT_REF:-}" ] && clone_args+=(--branch "$PREBOOT_REF")
git clone "${clone_args[@]}" "$repo_url" "$work_dir"

setup_args=(bash "$work_dir/setup.sh" --user "$(id -un)")

if [ "$module" = public-exposure ]; then
    # Retire the superseded preboot module if it is still installed.
    sudo rm -rf /usr/lib/dracut/modules.d/99frpc

    env_file="$INFRA_ROOT/config/$target/compose.env"
    [ -f "$env_file" ] || { echo "Error: $env_file not found" >&2; exit 1; }
    hub_host=$(grep -E '^PUBLIC_EXPOSURE_HOST=' "$env_file" | head -1 | cut -d= -f2- | tr -d '"'"'"' ')
    hub_port=$(grep -E '^PUBLIC_EXPOSURE_PORT=' "$env_file" | head -1 | cut -d= -f2- | tr -d '"'"'"' ')
    hub_port="${hub_port:-51822}"
    [ -n "$hub_host" ] || { echo "Error: PUBLIC_EXPOSURE_HOST must be set in $env_file" >&2; exit 1; }
    hub_ip=$(getent hosts "$hub_host" | awk '{print $1; exit}')
    [ -n "$hub_ip" ] || { echo "Error: cannot resolve PUBLIC_EXPOSURE_HOST '$hub_host'" >&2; exit 1; }

    keys_dir="$INFRA_ROOT/config/$target/public-exposure"
    for f in pre0.key server.pub; do
        [ -f "$keys_dir/$f" ] || { echo "Error: $keys_dir/$f not found (run scripts/public-exposure-keygen.sh)" >&2; exit 1; }
    done

    conf="$work_dir/pubexp-pre0.wg"
    {
        echo "[Interface]"
        echo "PrivateKey = $(<"$keys_dir/pre0.key")"
        echo
        echo "[Peer]"
        echo "PublicKey = $(<"$keys_dir/server.pub")"
        echo "Endpoint = $hub_ip:$hub_port"
        echo "AllowedIPs = 10.99.0.1/32"
        echo "PersistentKeepalive = 25"
    } >"$conf"
    chmod 600 "$conf"

    setup_args+=(--pubexp-conf "$conf")
else
    sed -i 's/^dropbear_port="22"/dropbear_port="8887"/' "$work_dir/modules/99crypt-ssh/crypt-ssh.conf"
fi

sudo "${setup_args[@]}"
rm -rf "$work_dir"

echo "Preboot $module installed — on the next boot, LUKS unlock runs before root is mounted."
