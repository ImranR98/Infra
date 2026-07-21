#!/bin/bash
# DESC: Host preparation for control-plane / storage nodes
# Idempotent. Called by setup.sh and join.sh BEFORE K3s starts.
set -euo pipefail

# K3s state directory for NFS-backed persistent storage.
#
# NOTE: NFS static PV capacity.storage is not a quota.  Pods can write
# up to the free space available on the host filesystem underlying
# this directory.  The PVC size in the spec is a scheduling/binding
# hint — the kernel and NFS server do not enforce it.
mkdir -p "$K3S_STATE_DIR"

# Pre-create NFS subdirectories for all persistent volumes.
# The CSI NFS driver mounts the parent share; the subDir parameter
# only appends to the mount path — it doesn't create the directory.
# We scan prereqs.yaml across all k3s components for 'subDir:' lines
# to discover what directories are needed.
if [ -d "$ATLAS_ROOT/targets/$TARGET/k3s" ]; then
    grep -rhoP 'subDir:\s*\K\S+' "$ATLAS_ROOT/targets/$TARGET/k3s"/*/prereqs.yaml 2>/dev/null | sort -u | while read subdir; do
        mkdir -p "$K3S_STATE_DIR/$subdir"
    done
fi
