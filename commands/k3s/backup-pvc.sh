#!/bin/bash
# DESC: Manually back up a single PVC on demand
# NOTE: Does NOT scale down workloads — backup captures live running state.
set -euo pipefail

source "$ATLAS_ROOT/lib/common.sh"
source_env

PVC_NAME="${1:?Usage: $0 <pvc-name> [-y]}"
shift
AUTO_YES=false
if [ "${1:-}" = "-y" ]; then AUTO_YES=true; shift; fi

BACKUP_FILE="$PVC_BACKUP_DIR/${PVC_NAME}.tar.gz"
mkdir -p "$PVC_BACKUP_DIR"
chcon -t container_file_t -l s0 "$PVC_BACKUP_DIR" 2>/dev/null || true

PVC_NS=$(pvc_find_namespace "$PVC_NAME")
if [ -z "$PVC_NS" ]; then
    echo "Error: PVC $PVC_NAME not found in cluster" >&2
    exit 1
fi

echo "Discovering workloads using $PVC_NS/$PVC_NAME..."
WORKLOADS=$(pvc_find_workloads "$PVC_NS" "$PVC_NAME")

if [ -n "$WORKLOADS" ]; then
    echo ""
    echo "WARNING: The following workloads are currently running. Backup will"
    echo "capture live state without scaling them down. If this PVC backs a"
    echo "database the archive may be inconsistent."
    echo ""
    echo "Running workloads:"
    for w in $WORKLOADS; do echo "  $w"; done
    echo ""
else
    echo "No running workloads found referencing this PVC."
    echo ""
fi

if [ "$AUTO_YES" = false ]; then
    read -p "Proceed with backup? [y/N] " confirm
    case "$confirm" in [yY]*) ;; *) echo "Aborted."; exit 0 ;; esac
fi

TIMESTAMP=$(date -Iseconds)

echo ""
echo "Backing up $PVC_NS/$PVC_NAME..."
BACKUP_POD="backup-$(echo "$PVC_NAME" | tr '_' '-')"
pvc_backup_pod_yaml "$PVC_NAME" "$PVC_NS" "$PVC_BACKUP_DIR" "${PVC_NAME}.tar.gz" "$TIMESTAMP" | kubectl apply -f -

echo "Waiting for backup pod to complete..."
if ! kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$BACKUP_POD" -n "$PVC_NS" --timeout=600s 2>/dev/null; then
    echo "Error: backup pod did not succeed — check pod logs with:" >&2
    echo "  kubectl logs $BACKUP_POD -n $PVC_NS" >&2
    kubectl delete pod "$BACKUP_POD" -n "$PVC_NS" --ignore-not-found 2>/dev/null || true
    exit 1
fi
kubectl delete pod "$BACKUP_POD" -n "$PVC_NS" --ignore-not-found 2>/dev/null

echo ""
echo "Backup of $PVC_NAME complete."
echo "Archive: $BACKUP_FILE"
