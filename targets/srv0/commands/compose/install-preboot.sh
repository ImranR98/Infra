#!/bin/bash
# DESC: Install preboot FRPC for remote LUKS unlock via SSH
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"

echo "=== Check if root partition is LUKS-encrypted ==="
if bash "$ATLAS_ROOT/commands/compose/check_root_luks.sh"; then
    echo "LUKS detected. Installing remote unlock..."
    configure_compose_templates "$TARGET"

    TMPDIR="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR"' EXIT
    git clone --depth 1 https://github.com/ImranR98/dracut-remote-luks-unlock.git "$TMPDIR"
    $(get_sudo_cmd) bash "$TMPDIR/setup.sh" \
        --frpc-config "$COMPOSE_STATE_DIR/frpc/frpc-preboot.toml" \
        --frpc-cert   "$COMPOSE_STATE_DIR/frpc/preboot-client.crt" \
        --frpc-key    "$COMPOSE_STATE_DIR/frpc/preboot-client.key" \
        --frpc-ca     "$COMPOSE_STATE_DIR/frpc/ca.crt" \
        --user        "$(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")"
    rm -rf "$TMPDIR"

    echo ""
    echo "Preboot FRPC installed. The initramfs has been rebuilt."
    echo "On the next boot, FRPC will start before root is mounted,"
    echo "tunneling SSH to the FRPS server on port 8887."
else
    echo "Root partition is not LUKS-encrypted. Skipping preboot setup."
    echo "If you add LUKS later, re-run this command."
fi
