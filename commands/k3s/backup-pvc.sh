#!/bin/bash
# DESC: Back up PVCs — single by name, or mass via --all (auto-backup labeled).
# NOTE: Does NOT scale down workloads — backup captures live running state.
set -euo pipefail

source "$INFRA_ROOT/lib/common.sh"

# Allow CronJob pod to bypass source_env (vars already in environment).
if [ -z "${PVC_BACKUP_DIR:-}" ]; then
    source_env
fi

ALL_MODE=false
if [ "${1:-}" = "--all" ]; then
    ALL_MODE=true
    shift
fi

AUTO_YES=false
if [ "${1:-}" = "-y" ]; then AUTO_YES=true; shift; fi

if $ALL_MODE; then
    if ! $AUTO_YES && ! _confirm "Back up all auto-backup labeled PVCs?"; then
        echo "Aborted."; exit 0
    fi
    pvc_backup_all true
    exit $?
fi

# --- single-PVC path (unchanged) -------------------------------------------
PVC_NAME="${1:?Usage: $0 <pvc-name> | --all [-y]}"

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

if [ "$AUTO_YES" = false ] && ! _confirm "Proceed with backup?"; then
    echo "Aborted."; exit 0
fi

TIMESTAMP=$(date -Iseconds)

echo ""
echo "Backing up $PVC_NS/$PVC_NAME..."

EXCLUDE=$(kubectl get pvc "$PVC_NAME" -n "$PVC_NS" -o jsonpath='{.metadata.annotations.backup\.infra/exclude}' 2>/dev/null || echo "")

pvc_backup_data "$PVC_NAME" "$PVC_NS" "$PVC_BACKUP_DIR" "${PVC_NAME}.tar.gz" "$TIMESTAMP" "$EXCLUDE" \
    || { echo "Backup failed." >&2; exit 1; }

echo ""
echo "Backup of $PVC_NAME complete."
echo "Archive: $BACKUP_FILE"
