#!/bin/bash
# DESC: Install preboot FRPC for remote LUKS unlock via SSH
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"
COMP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../compose" >/dev/null 2>&1 && pwd)"

echo "=== Check if root partition is LUKS-encrypted ==="
if bash "$COMP_DIR/check_root_luks.sh"; then
	echo "LUKS detected. Installing preboot FRPC and dracut-crypt-ssh..."
	configure_compose_templates "$TARGET"
	$(get_sudo_cmd) bash "$COMP_DIR/dracut-crypt-ssh.install.sh" "$(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")"
	$(get_sudo_cmd) bash "$COMP_DIR/frpc-preboot.install.sh" "$COMPOSE_STATE_DIR"
	echo ""
	echo "Preboot FRPC installed. The initramfs has been rebuilt."
	echo "On the next boot, FRPC will start before root is mounted,"
	echo "tunneling SSH to the FRPS server on port 8887."
else
	echo "Root partition is not LUKS-encrypted. Skipping preboot setup."
	echo "If you add LUKS later, re-run this command."
fi
