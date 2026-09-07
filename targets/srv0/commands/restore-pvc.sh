#!/bin/bash
# DESC: Restore PVCs from backup archives — single by name, or mass via --all.
set -euo pipefail

source "$INFRA_ROOT/lib/common.sh"
# pvc.sh is target-specific (srv0 k3s cluster) — sourced directly, not via common.sh.
source "$INFRA_ROOT/targets/srv0/commands/pvc.sh"

ALL_MODE=false
if [ "${1:-}" = "--all" ]; then
    ALL_MODE=true
    shift
fi

AUTO_YES=false
if [ "${1:-}" = "-y" ]; then AUTO_YES=true; shift; fi

if $ALL_MODE; then
    if ! $AUTO_YES && ! _confirm "Restore all auto-backup labeled PVCs from backup archives?"; then
        echo "Aborted."; exit 0
    fi
    pvc_restore_all true
    exit $?
fi

# --- single-PVC path (unchanged) -------------------------------------------
PVC_NAME="${1:?Usage: $0 <pvc-name> | --all [-y]}"

BACKUP_FILE="$PVC_BACKUP_DIR/${PVC_NAME}.tar.gz"

if [ ! -f "$BACKUP_FILE" ]; then
    echo "Error: backup not found at $BACKUP_FILE" >&2
    exit 1
fi

if [ ! -s "$BACKUP_FILE" ]; then
    echo "Error: backup archive at $BACKUP_FILE is empty" >&2
    exit 1
fi

PVC_NS=$(pvc_find_namespace "$PVC_NAME")
if [ -z "$PVC_NS" ]; then
    echo "Error: PVC $PVC_NAME not found in cluster" >&2
    exit 1
fi

echo "Discovering workloads using $PVC_NS/$PVC_NAME..."
WORKLOADS=$(pvc_find_workloads "$PVC_NS" "$PVC_NAME")

if [ -z "$WORKLOADS" ]; then
    echo "WARNING: no workloads found referencing $PVC_NAME" >&2
else
    echo ""
    echo "The following workloads will be scaled down during restore:"
    for w in $WORKLOADS; do echo "  $w"; done
    echo ""
fi

if [ "$AUTO_YES" = false ] && ! _confirm "Proceed with restore?"; then
    echo "Aborted."; exit 0
fi

SCALED_FILE=$(mktemp)
trap 'pvc_scale_restore "$SCALED_FILE"; rm -f "$SCALED_FILE"' EXIT

pvc_scale_down "$PVC_NS" "$PVC_NAME" "$SCALED_FILE"
echo "Waiting for pods to terminate..."
pvc_wait_pods_gone "$SCALED_FILE"

echo "Waiting for PVC to be ready for mounting..."
pvc_wait_bound "$PVC_NS" "$PVC_NAME" 150 || exit 1

TIMESTAMP=$(tar xzf "$BACKUP_FILE" __backup_timestamp.txt -O 2>/dev/null || echo "unknown")
echo ""
echo "Restoring from backup taken at: $TIMESTAMP"

pvc_restore_data "$PVC_NAME" "$PVC_NS" "$PVC_BACKUP_DIR" "${PVC_NAME}.tar.gz" \
    || { echo "Restore failed." >&2; exit 1; }

echo ""
echo "Restore of $PVC_NAME complete."
