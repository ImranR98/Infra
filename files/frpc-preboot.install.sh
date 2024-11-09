#!/bin/bash
set -e
HERE_A7H2="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# Generate/update config
bash "$HERE_A7H2"/frpc.generate.sh preboot

# Install/update dracut-frpc
temp_dir="$(mktemp -d)"
working_dir="$(pwd)"
cd "$temp_dir"
git clone https://github.com/ImranR98/dracut-frpc.git
cd dracut-frpc
bash ./setup.sh "$HERE_A7H2"/frpc-preboot.ini
cd "$working_dir"