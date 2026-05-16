#!/bin/bash
set -e

STATE_DIR="$1"
if [ -z "$STATE_DIR" ]; then exit 1; fi

PRESET_PATH="$STATE_DIR/frpc/frpc-preboot.toml"

temp_dir="$(mktemp -d)"
working_dir="$(pwd)"
cd "$temp_dir"
git clone https://github.com/ImranR98/dracut-frpc.git
cd dracut-frpc
export RUN_TOOLBOX_STEPS_WITH_ASSUMPTIONS=true
bash ./setup.sh "$PRESET_PATH"
rm -rf "$temp_dir"
cd "$working_dir"
