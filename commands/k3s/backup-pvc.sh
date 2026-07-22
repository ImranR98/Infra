#!/bin/bash
# DESC: Manually back up a single PVC on demand
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

# Find workloads using this PVC (deployments and statefulsets only;
# DaemonSets cannot be scaled down so they are skipped).
echo "Discovering workloads using $PVC_NS/$PVC_NAME..."
WORKLOADS=$(kubectl get deploy,sts -n "$PVC_NS" -o json 2>/dev/null | jq -r --arg pvc "$PVC_NAME" \
    '.items[] | select(.spec.template.spec.volumes[]?.persistentVolumeClaim.claimName == $pvc) | "\(.kind)/\(.metadata.name)"' 2>/dev/null || true)

TIMESTAMP=$(date -Iseconds)

if [ -z "$WORKLOADS" ]; then
    echo ""
    echo "WARNING: no Deployments or StatefulSets found referencing $PVC_NAME" >&2
    echo "The PVC will be backed up without scaling anything down.  If another"
    echo "workload (e.g. a DaemonSet or standalone Pod) is actively writing to"
    echo "this PVC the backup may be inconsistent." >&2
    echo ""
else
    echo ""
    echo "The following workloads will be scaled down during backup:"
    for w in $WORKLOADS; do
        echo "  $w"
    done
    echo ""
fi

if [ "$AUTO_YES" = false ]; then
    read -p "Proceed with backup? [y/N] " confirm
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
    kubectl delete pod -n "$PVC_NS" -l app=pvc-backup-temp --wait=false 2>/dev/null || true
}

for w in $WORKLOADS; do
    wkind="${w%%/*}"
    wname="${w##*/}"
    reps=$(kubectl get "$wkind" "$wname" -n "$PVC_NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
    echo "$wkind/$wname/$reps" >> "$SCALED_FILE"
    if [ "$reps" = "0" ]; then
        echo "$wkind/$wname already at 0; skipping"
        continue
    fi
    echo "Scaling $wkind/$wname to 0..."
    kubectl scale "$wkind" "$wname" -n "$PVC_NS" --replicas=0
done

# Wait for old pods to terminate so the RWO PVC is released
if [ -n "$WORKLOADS" ] && grep -q . "$SCALED_FILE" 2>/dev/null; then
    echo "Waiting for pods to terminate..."
    for w in $WORKLOADS; do
        wkind="${w%%/*}"
        wname="${w##*/}"
        selector=$(kubectl get "$wkind" "$wname" -n "$PVC_NS" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
        if [ -n "$selector" ]; then
            if ! kubectl wait --for=delete pod -n "$PVC_NS" --selector="$selector" --timeout=180s 2>/dev/null; then
                echo "WARNING: pods for $wkind/$wname did not terminate within 180s — backup may fail if PVC is still attached" >&2
            fi
        fi
    done
fi

# Wait for PVC to be released and re-available
echo "Waiting for PVC to be ready for mounting..."
retry 30 5 "kubectl get pvc \"$PVC_NAME\" -n \"$PVC_NS\" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Bound" || {
    echo "Error: PVC $PVC_NAME did not become Bound within timeout" >&2
    exit 1
}

# Run backup pod
echo ""
echo "Backing up $PVC_NS/$PVC_NAME..."
BACKUP_POD="backup-$(echo "$PVC_NAME" | tr '_' '-')"
cat <<PODEOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $BACKUP_POD
  namespace: $PVC_NS
  labels:
    app: pvc-backup-temp
spec:
  securityContext:
    runAsUser: ${MY_UID}
    runAsGroup: ${MY_UID}
    fsGroup: ${MY_UID}
  restartPolicy: Never
  containers:
  - name: backup
    image: alpine:3.21
    securityContext:
      seLinuxOptions:
        level: s0
    command:
    - sh
    - -c
    - |
      echo "$TIMESTAMP" > /data/__backup_timestamp.txt
      if ! tar czf /backup/"$PVC_NAME".tar.gz -C /data .; then
        echo "ERROR: tar archive creation failed" >&2
        rm -f /data/__backup_timestamp.txt
        exit 1
      fi
      rm -f /data/__backup_timestamp.txt
      if [ ! -s /backup/"$PVC_NAME".tar.gz ]; then
        echo "ERROR: backup archive is empty" >&2
        exit 1
      fi
      chown ${MY_UID}:${MY_UID} /backup/"$PVC_NAME".tar.gz 2>/dev/null || true
    volumeMounts:
    - name: data
      mountPath: /data
      readOnly: true
    - name: backup-dest
      mountPath: /backup
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: $PVC_NAME
  - name: backup-dest
    hostPath:
      path: $PVC_BACKUP_DIR
      type: DirectoryOrCreate
PODEOF

echo "Waiting for backup pod to complete..."
if ! kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$BACKUP_POD" -n "$PVC_NS" --timeout=600s 2>/dev/null; then
    echo "Error: backup pod did not succeed — check pod logs with:" >&2
    echo "  kubectl logs $BACKUP_POD -n $PVC_NS" >&2
    kubectl delete pod "$BACKUP_POD" -n "$PVC_NS" 2>/dev/null || true
    exit 1
fi
kubectl delete pod "$BACKUP_POD" -n "$PVC_NS"

# On success, workloads are still at 0 — trap restores them on exit
echo ""
echo "Backup of $PVC_NAME complete."
echo "Archive: $BACKUP_FILE"
