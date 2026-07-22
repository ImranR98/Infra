#!/bin/bash
# DESC: Pre-create NFS subdirs on the hostpath-main node before nfs-server starts.
# Runs locally when the CP node is also the NFS node, or via SSH for remote nodes.
set -euo pipefail

NFS_NODE=$(kubectl get nodes -l hostpath-main=true -o jsonpath='{.items[0].metadata.name}')
[ -n "$NFS_NODE" ] || { echo "Error: No node labeled hostpath-main=true" >&2; exit 1; }

NFS_IP=$(kubectl get node "$NFS_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

_is_local() {
    [ "$(hostname)" = "$NFS_NODE" ] || [ "$(hostname -f 2>/dev/null)" = "$NFS_NODE" ]
}

_dir_exists() {
    if _is_local; then
        [ -d "$1" ]
    else
        ssh "root@$NFS_IP" "test -d '$1'"
    fi
}

_create_dir() {
    local dir="$1"
    if _is_local; then
        mkdir -p "$dir"
    else
        ssh "root@$NFS_IP" "mkdir -p '$dir' && chown '${MY_UID:-1000}:${MY_UID:-1000}' '$dir'"
    fi
}

grep -rhoP 'subDir:\s*\K\S+' "$ATLAS_ROOT/targets/$TARGET/k3s"/*/prereqs.yaml 2>/dev/null | sort -u | while read subdir; do
    if _dir_exists "$K3S_STATE_DIR/$subdir"; then
        continue
    fi
    echo "Creating $subdir"
    _create_dir "$K3S_STATE_DIR/$subdir"
done
