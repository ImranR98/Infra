#!/bin/bash
# DESC: Restore a PVC from a backup archive
set -euo pipefail

source "$ATLAS_ROOT/lib/common.sh"
source_env

PVC_NAME="${1:?Usage: $0 <pvc-name> [-y]}"
shift
AUTO_YES=false
if [ "${1:-}" = "-y" ]; then AUTO_YES=true; shift; fi

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

if [ "$AUTO_YES" = false ]; then
    read -p "Proceed with restore? [y/N] " confirm
    case "$confirm" in [yY]*) ;; *) echo "Aborted."; exit 0 ;; esac
fi

SCALED_FILE=$(mktemp)
trap 'pvc_scale_restore "$PVC_NS" "$SCALED_FILE"; rm -f "$SCALED_FILE"' EXIT

pvc_scale_down "$PVC_NS" "$PVC_NAME" "$SCALED_FILE"
echo "Waiting for pods to terminate..."
pvc_wait_pods_gone "$PVC_NS" "$SCALED_FILE"

echo "Waiting for PVC to be ready for mounting..."
pvc_wait_bound "$PVC_NS" "$PVC_NAME" 150 || exit 1

TIMESTAMP=$(tar xzf "$BACKUP_FILE" __backup_timestamp.txt -O 2>/dev/null || echo "unknown")
echo ""
echo "Restoring from backup taken at: $TIMESTAMP"

RESTORE_POD="restore-$(echo "$PVC_NAME" | tr '_' '-')"
pvc_restore_pod_yaml "$PVC_NAME" "$PVC_NS" "$PVC_BACKUP_DIR" "${PVC_NAME}.tar.gz" | kubectl apply -f -

echo "Waiting for restore pod to complete..."
if ! kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$RESTORE_POD" -n "$PVC_NS" --timeout=600s 2>/dev/null; then
    echo "Error: restore pod did not succeed — check pod logs with:" >&2
    echo "  kubectl logs $RESTORE_POD -n $PVC_NS" >&2
    kubectl delete pod "$RESTORE_POD" -n "$PVC_NS" --ignore-not-found 2>/dev/null || true
    exit 1
fi
kubectl delete pod "$RESTORE_POD" -n "$PVC_NS" --ignore-not-found 2>/dev/null

echo ""
echo "Restore of $PVC_NAME complete."
