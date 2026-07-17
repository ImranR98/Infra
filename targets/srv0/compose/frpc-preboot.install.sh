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
bash ./setup.sh "$PRESET_PATH"
cd "$working_dir"
