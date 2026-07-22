#!/bin/bash
# DESC: Host preparation for control-plane / storage nodes
# Idempotent. Called by setup.sh and join.sh BEFORE K3s starts.
set -euo pipefail

# NFS static PV capacity.storage is only a scheduling hint, not a quota.
mkdir -p "$K3S_STATE_DIR"
[ "$(stat -c '%U' "$K3S_STATE_DIR" 2>/dev/null)" != "${MY_UID:-1000}" ] && chown "${MY_UID:-1000}:${MY_UID:-1000}" "$K3S_STATE_DIR" 2>/dev/null || true

# NFS subdirectories are pre-created by the nfs-server component's prep.sh,
# which runs on every deploy and targets the hostpath-main=true node.
