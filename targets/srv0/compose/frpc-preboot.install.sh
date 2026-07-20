#!/bin/bash
set -euo pipefail

COMPOSE_STATE_DIR="$1"
if [ -z "$COMPOSE_STATE_DIR" ]; then exit 1; fi

PRESET_PATH="$COMPOSE_STATE_DIR/frpc/frpc-preboot.toml"

temp_dir="$(mktemp -d)"
working_dir="$(pwd)"
trap 'rm -rf "$temp_dir"' EXIT
cd "$temp_dir"
git clone --depth 1 https://github.com/ImranR98/dracut-frpc.git
cd dracut-frpc
# Skips interactive prompts in the setup script (assumes default answers).
# Required for non-interactive initramfs installation.
export RUN_TOOLBOX_STEPS_WITH_ASSUMPTIONS=true
CERT_DIR="$COMPOSE_STATE_DIR/frpc"
if [ -f "$CERT_DIR/ca.crt" ] && [ -f "$CERT_DIR/preboot-client.crt" ] && [ -f "$CERT_DIR/preboot-client.key" ]; then
    cp "$CERT_DIR/ca.crt" modules/99frpc/ca.crt
    cp "$CERT_DIR/preboot-client.crt" modules/99frpc/client.crt
    cp "$CERT_DIR/preboot-client.key" modules/99frpc/client.key
    bash ./setup.sh --cert modules/99frpc/client.crt --key modules/99frpc/client.key --ca modules/99frpc/ca.crt "$PRESET_PATH"
else
    echo "Warning: preboot TLS certificates not found in $CERT_DIR" >&2
    echo "Preboot FRPC will be installed without mTLS." >&2
    bash ./setup.sh "$PRESET_PATH"
fi
cd "$working_dir"
