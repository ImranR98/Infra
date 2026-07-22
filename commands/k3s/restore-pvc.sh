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

# Verify archive is non-empty before proceeding
if [ ! -s "$BACKUP_FILE" ]; then
    echo "Error: backup archive at $BACKUP_FILE is empty" >&2
    exit 1
fi

# Find namespace from the PVC
# NOTE: queries all namespaces — if two PVCs share a name across
# namespaces the first JSON result is used. Specify the namespace
# explicitly if this ambiguity could exist.
PVC_NS=$(kubectl get pvc -A -o json 2>/dev/null | jq -r --arg name "$PVC_NAME" \
    '.items[] | select(.metadata.name == $name) | .metadata.namespace' 2>/dev/null || true)
if [ -z "$PVC_NS" ]; then
    echo "Error: PVC $PVC_NAME not found in cluster" >&2
    exit 1
fi

# Find workloads using this PVC
echo "Discovering workloads using $PVC_NS/$PVC_NAME..."
WORKLOADS=$(kubectl get deploy,sts -n "$PVC_NS" -o json 2>/dev/null | jq -r --arg pvc "$PVC_NAME" \
    '.items[] | select(.spec.template.spec.volumes[]?.persistentVolumeClaim.claimName == $pvc) | "\(.kind)/\(.metadata.name)"' 2>/dev/null || true)

if [ -z "$WORKLOADS" ]; then
    echo "WARNING: no workloads found referencing $PVC_NAME" >&2
else
    echo ""
    echo "The following workloads will be scaled down during restore:"
    for w in $WORKLOADS; do
        echo "  $w"
    done
    echo ""
fi

if [ "$AUTO_YES" = false ]; then
    read -p "Proceed with restore? [y/N] " confirm
    case "$confirm" in [yY]*) ;; *) echo "Aborted."; exit 0 ;; esac
fi

SCALED_FILE=$(mktemp)
trap '_restore_workloads; rm -f "$SCALED_FILE"' EXIT

_restore_workloads() {
    if [ -f "$SCALED_FILE" ]; then
        while IFS= read -r entry; do
            wkind=$(echo "$entry" | cut -d/ -f1)
            wname=$(echo "$entry" | cut -d/ -f2)
            reps=$(echo "$entry" | cut -d/ -f3)
            echo "Restoring $wkind/$wname to $reps replicas..."
            kubectl scale "$wkind" "$wname" -n "$PVC_NS" --replicas="$reps" 2>/dev/null || \
                echo "WARNING: failed to restore $wkind/$wname — it may still be scaled to 0" >&2
        done < "$SCALED_FILE"
    fi
    kubectl delete pod -n "$PVC_NS" -l app=pvc-restore-temp --wait=false 2>/dev/null || true
}

for w in $WORKLOADS; do
    wkind="${w%%/*}"
    wname="${w##*/}"
    reps=$(kubectl get "$wkind" "$wname" -n "$PVC_NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
    echo "$wkind/$wname/$reps" >> "$SCALED_FILE"
    echo "Scaling $wkind/$wname to 0..."
    kubectl scale "$wkind" "$wname" -n "$PVC_NS" --replicas=0
done

# Wait for old pods to fully terminate so the RWO PVC is released
echo "Waiting for pods to terminate..."
for w in $WORKLOADS; do
    wkind="${w%%/*}"
    wname="${w##*/}"
    selector=$(kubectl get "$wkind" "$wname" -n "$PVC_NS" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
    if [ -n "$selector" ]; then
        if ! kubectl wait --for=delete pod -n "$PVC_NS" --selector="$selector" --timeout=180s 2>/dev/null; then
            echo "WARNING: pods for $wkind/$wname did not terminate within 180s — restore may fail if PVC is still attached" >&2
        fi
    fi
done

# Wait for PVC to be released and re-available
echo "Waiting for PVC to be ready for mounting..."
retry 30 5 "kubectl get pvc \"$PVC_NAME\" -n \"$PVC_NS\" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Bound" || {
    echo "Error: PVC $PVC_NAME did not become Bound within timeout" >&2
    exit 1
}

# Run restore pod
TIMESTAMP=$(tar xzf "$BACKUP_FILE" __backup_timestamp.txt -O 2>/dev/null || echo "unknown")
echo ""
echo "Restoring from backup taken at: $TIMESTAMP"

RESTORE_POD="restore-$(echo "$PVC_NAME" | tr '_' '-')"
cat <<PODEOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $RESTORE_POD
  namespace: $PVC_NS
  labels:
    app: pvc-restore-temp
spec:
  securityContext:
    runAsUser: ${MY_UID}
    runAsGroup: ${MY_UID}
    fsGroup: ${MY_UID}
  restartPolicy: Never
  containers:
  - name: restore
    image: alpine:3.21
    securityContext:
      seLinuxOptions:
        level: s0
    command:
    - sh
    - -c
    - |
      if ! mountpoint /data; then
        echo "ERROR: PVC not mounted at /data" >&2
        exit 1
      fi
      rm -rf /data/*
      tar xzf /backup/${PVC_NAME}.tar.gz -C /data --exclude=__backup_timestamp.txt
    volumeMounts:
    - name: data
      mountPath: /data
    - name: backup-src
      mountPath: /backup
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: $PVC_NAME
  - name: backup-src
    hostPath:
      path: $PVC_BACKUP_DIR
      type: DirectoryOrCreate
PODEOF

echo "Waiting for restore pod to complete..."
if ! kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$RESTORE_POD" -n "$PVC_NS" --timeout=600s 2>/dev/null; then
    echo "Error: restore pod did not succeed — check pod logs with:" >&2
    echo "  kubectl logs $RESTORE_POD -n $PVC_NS" >&2
    kubectl delete pod "$RESTORE_POD" -n "$PVC_NS" 2>/dev/null || true
    exit 1
fi
kubectl delete pod "$RESTORE_POD" -n "$PVC_NS"

# On success, workloads are still at 0 — trap restores them on exit
echo ""
echo "Restore of $PVC_NAME complete."
