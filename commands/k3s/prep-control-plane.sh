#!/bin/bash
# DESC: Host preparation for control-plane / storage nodes
# Idempotent. Called by setup.sh and join.sh BEFORE K3s starts.
: ${ATLAS_ROOT:="$(cd "$(dirname "$(readlink -f "$0")")/../.." >/dev/null 2>&1 && pwd)"}
: ${K3S_STATE_DIR:="$ATLAS_ROOT/current_target/k3s_live_state"}
set -euo pipefail

# K3s state directory for NFS-backed persistent storage.
#
# NOTE: NFS static PV capacity.storage is not a quota.  Pods can write
# up to the free space available on the host filesystem underlying
# this directory.  The PVC size in the spec is a scheduling/binding
# hint — the kernel and NFS server do not enforce it.
mkdir -p "$K3S_STATE_DIR"

# Pre-create NFS subdirectories for all persistent volumes.
# The CSI NFS driver mounts the parent share; subdirs must already
# exist on the NFS server or the mount will fail with ENOENT.
for subdir in \
	authelia-db authelia-session crowdsec ntfy \
	fmd freshrss-data freshrss-extensions gokapi-data gokapi-config \
	homeassistant-config immich-db immich-library jellyfin-config \
	mosquitto-data navidrome-data nextcloud-data nextcloud-db \
	ollama-models openwebui-data opodsync; do
	mkdir -p "$K3S_STATE_DIR/$subdir"
done
