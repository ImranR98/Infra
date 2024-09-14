#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE"/../helpers.sh

# Generate/update config
bash "$HERE"/files/generate_config.sh

# Create Secret
kubectl -n production get secret frpc-config 2>/dev/null && kubectl -n production delete secret frpc-config || :
kubectl create -n production secret generic frpc-config --from-file="$HERE/frpc.ini"