#!/bin/bash
# DESC: Expand a Mayastor DiskPool to a larger size
set -euo pipefail

source "$ATLAS_ROOT/lib/common.sh"

NEW_SIZE="${1:?Usage: $0 <size> (e.g. 2T, 500GiB)}"

POOL="${2:-srv0-pool}"
POOL_NS="openebs"

# --- validate pool exists ---
if ! kubectl get dsp -n "$POOL_NS" "$POOL" >/dev/null 2>&1; then
	echo "ERROR: DiskPool '$POOL' not found in namespace '$POOL_NS'" >&2
	exit 1
fi

# --- check pool is online ---
STATUS=$(kubectl get dsp -n "$POOL_NS" "$POOL" -o jsonpath='{.status.pool_status}' 2>/dev/null)
if [ "$STATUS" != "Online" ]; then
	echo "ERROR: DiskPool '$POOL' is not Online (status: $STATUS)" >&2
	exit 1
fi

# --- check max expandable size ---
MAX_EXPAND=$(kubectl get dsp -n "$POOL_NS" "$POOL" -o jsonpath='{.status.maxExpandableSize}' 2>/dev/null)
DISK_PATH=$(kubectl get dsp -n "$POOL_NS" "$POOL" -o jsonpath='{.spec.disks[0]}' 2>/dev/null)
HOST_PATH=$(echo "$DISK_PATH" | sed 's|^aio:///*|/|')
CUR_SIZE=$(stat -c %s "$HOST_PATH" 2>/dev/null || echo 0)

if [ "$CUR_SIZE" -eq 0 ]; then
	echo "ERROR: cannot stat backing file at $HOST_PATH" >&2
	exit 1
fi

echo ""
echo "DiskPool:      $POOL"
echo "Backing file:  $HOST_PATH"
echo "Current size:  $(numfmt --to=iec "$CUR_SIZE" 2>/dev/null || echo "$CUR_SIZE" bytes)"
echo "New size:      $NEW_SIZE"
echo "Max expand:    $MAX_EXPAND"
echo ""

NEW_SIZE_BYTES=$(numfmt --from=iec "$NEW_SIZE" 2>/dev/null || { echo "ERROR: invalid size format '$NEW_SIZE'" >&2; exit 1; })
if [ "$NEW_SIZE_BYTES" -le "$CUR_SIZE" ]; then
	echo "ERROR: new size must be larger than current size" >&2
	exit 1
fi
MAX_EXPAND_BYTES=$(numfmt --from=iec "${MAX_EXPAND// /}" 2>/dev/null || echo 0)
if [ "$MAX_EXPAND_BYTES" -gt 0 ] && [ "$NEW_SIZE_BYTES" -gt "$MAX_EXPAND_BYTES" ]; then
	echo "ERROR: requested size exceeds max expandable size ($MAX_EXPAND)" >&2
	exit 1
fi

read -p "Expand pool? [y/N] " confirm
case "$confirm" in [yY]*) ;; *) echo "Aborted."; exit 0 ;; esac

# --- grow backing file ---
echo "Growing backing file..."
SUDO=$(get_sudo_cmd)
$SUDO truncate -s "$NEW_SIZE_BYTES" "$HOST_PATH"

# --- trigger expansion ---
echo "Triggering pool expansion..."
kubectl annotate dsp -n "$POOL_NS" "$POOL" openebs.io/expand=true --overwrite

# --- wait for expansion ---
echo "Waiting for expansion to complete..."
for i in $(seq 1 60); do
	CAP=$(kubectl get dsp -n "$POOL_NS" "$POOL" -o jsonpath='{.status.capacity_q}' 2>/dev/null)
	STATUS=$(kubectl get dsp -n "$POOL_NS" "$POOL" -o jsonpath='{.status.pool_status}' 2>/dev/null)
	echo "  [$i/60] capacity=$CAP status=$STATUS"
	if [ "$STATUS" = "Online" ] && [ -n "$CAP" ] && [ "$CAP" != "0 B" ]; then
		break
	fi
	sleep 3
done

echo ""
echo "=== Result ==="
kubectl get dsp -n "$POOL_NS" "$POOL"
