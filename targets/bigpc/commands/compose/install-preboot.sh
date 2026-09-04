#!/bin/bash
# DESC: Install crypt-ssh preboot for remote LUKS unlock via SSH
set -euo pipefail
source "$INFRA_ROOT/lib/common.sh"

echo "=== Check if root partition is LUKS-encrypted ==="
if bash "$INFRA_ROOT/lib/check_root_luks.sh"; then
    PREBOOT_PORT="${FRPS_PREBOOT_PORT:-8887}"
    echo "LUKS detected. Installing crypt-ssh remote unlock (port $PREBOOT_PORT)..."

    TMPDIR="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR"' EXIT
    git clone --depth 1 https://github.com/ImranR98/dracut-remote-luks-unlock.git "$TMPDIR"
    # Direct LAN access (no FRP tunnel): make the initramfs SSH listen on the preboot port
    sed -i "s/dropbear_port=\"22\"/dropbear_port=\"$PREBOOT_PORT\"/" "$TMPDIR/modules/99crypt-ssh/crypt-ssh.conf"
    $(get_sudo_cmd) bash "$TMPDIR/setup.sh" \
        --module crypt-ssh \
        --user "$(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")"
    rm -rf "$TMPDIR"

    echo ""
    echo "Preboot crypt-ssh installed. The initramfs has been rebuilt."
    echo "On the next boot, an SSH server will start before root is mounted,"
    echo "listening on port $PREBOOT_PORT (direct LAN connection, no FRP tunnel)."
else
    echo "Root partition is not LUKS-encrypted. Skipping preboot setup."
    echo "If you add LUKS later, re-run this command."
fi
