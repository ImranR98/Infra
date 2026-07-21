#!/bin/bash
# DESC: Host preparation for control-plane / storage nodes
# Idempotent. Called by setup.sh and join.sh BEFORE K3s starts.
set -euo pipefail

# NFS static PV capacity.storage is only a scheduling hint, not a quota.
mkdir -p "$K3S_STATE_DIR"

# Pre-create NFS subdirs discovered from prereqs.yaml.  CSI driver's
# subDir only appends to the mount path — it doesn't create.  On remotes
# (join.sh has no ATLAS_ROOT/TARGET) this is skipped; the first CP node
# already created them on the shared NFS volume.
if [ -n "${ATLAS_ROOT:-}" ] && [ -n "${TARGET:-}" ] && [ -d "$ATLAS_ROOT/targets/$TARGET/k3s" ]; then
    grep -rhoP 'subDir:\s*\K\S+' "$ATLAS_ROOT/targets/$TARGET/k3s"/*/prereqs.yaml 2>/dev/null | sort -u | while read subdir; do
        mkdir -p "$K3S_STATE_DIR/$subdir"
    done
fi
