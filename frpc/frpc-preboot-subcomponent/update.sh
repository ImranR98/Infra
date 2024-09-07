#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# Generate/update config
bash "$HERE"/../files/generate_config.sh preboot

# Install/update dracut-frpc
temp_dir="$(mktemp -d)"
working_dir="$(pwd)"
cd "$temp_dir"
git clone https://github.com/ImranR98/dracut-frpc.git
cd dracut-frpc
bash ./setup.sh "$HERE"/../frpc-preboot.ini
cd "$working_dir"
