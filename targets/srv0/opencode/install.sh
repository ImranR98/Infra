#!/bin/bash
# DESC: Install and start the opencode-serve systemd user unit on srv0 — the
# host-run `opencode serve` bound to the cluster bridge, exposed VPN+LAN by the
# K3s Traefik edge. Enables lingering so it starts at boot without a login.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"
require_target_host srv0

usage() {
    echo "Usage: $(basename "$0")"
    echo
    echo "Installs targets/srv0/opencode/opencode-serve.service into the user"
    echo "systemd manager, enables lingering, and starts the service. Idempotent."
    exit 1
}

[ $# -ge 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; } && usage
[ $# -gt 0 ] && usage

src_dir="$INFRA_ROOT/targets/srv0/opencode"
unit_dir="$HOME/.config/systemd/user"

echo "==> Installing opencode-serve.service"
mkdir -p "$unit_dir"
install -m 0644 "$src_dir/opencode-serve.service" "$unit_dir/opencode-serve.service"

systemctl --user daemon-reload

echo "==> Enabling linger for $USER (start at boot, survive logout)"
loginctl enable-linger "$USER" 2>/dev/null ||
    echo "Warning: enable-linger failed; run: sudo loginctl enable-linger $USER"

echo "==> Enabling and starting opencode-serve"
systemctl --user enable --now opencode-serve.service

echo "Done. Inspect with: systemctl --user status opencode-serve"
