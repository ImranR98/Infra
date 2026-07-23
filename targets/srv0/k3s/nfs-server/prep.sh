#!/bin/bash
# DESC Pre-flight checks for the in-cluster NFS server (media shares only).
# Media directories are expected to exist on the hostpath-main node.
# K3S_STATE_DIR subDir creation was removed — all state PVCs now live on Longhorn.
set -euo pipefail

NFS_NODE=$(kubectl get nodes -l hostpath-main=true -o jsonpath='{.items[0].metadata.name}')
[ -n "$NFS_NODE" ] || { echo "Error: No node labeled hostpath-main=true" >&2; exit 1; }

echo "NFS server will run on node $NFS_NODE (media shares only)."
