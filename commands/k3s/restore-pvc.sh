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
	echo "ERROR: backup not found at $BACKUP_FILE" >&2
	exit 1
fi

# Find namespace from the PVC
PVC_NS=$(kubectl get pvc -A -o json 2>/dev/null | jq -r --arg name "$PVC_NAME" \
	'.items[] | select(.metadata.name == $name) | .metadata.namespace' 2>/dev/null || true)
if [ -z "$PVC_NS" ]; then
	echo "ERROR: PVC $PVC_NAME not found in cluster" >&2
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
trap 'restore_workloads; rm -f "$SCALED_FILE"' EXIT

restore_workloads() {
	if [ -f "$SCALED_FILE" ]; then
		while IFS= read -r entry; do
			wkind=$(echo "$entry" | cut -d/ -f1)
			wname=$(echo "$entry" | cut -d/ -f2)
			reps=$(echo "$entry" | cut -d/ -f3)
			kubectl scale "$wkind" "$wname" -n "$PVC_NS" --replicas="$reps" 2>/dev/null || true
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

# Wait for pods to terminate
sleep 5
for w in $WORKLOADS; do
	wkind="${w%%/*}"
	wname="${w##*/}"
	echo "Waiting for $wkind/$wname pods to terminate..."
	kubectl wait --for=delete pod -n "$PVC_NS" --selector="$(kubectl get "$wkind" "$wname" -n "$PVC_NS" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')" --timeout=120s 2>/dev/null || true
done

# Run restore pod
TIMESTAMP=$(tar xzf "$BACKUP_FILE" timestamp.txt -O 2>/dev/null || echo "unknown")
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
  restartPolicy: Never
  containers:
  - name: restore
    image: alpine:3.21
    command:
    - sh
    - -c
    - |
      rm -rf /data/*
      tar xzf /backup/${PVC_NAME}.tar.gz -C /data --exclude=timestamp.txt
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
      type: Directory
PODEOF

echo "Waiting for restore pod to complete..."
if ! kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$RESTORE_POD" -n "$PVC_NS" --timeout=600s 2>/dev/null; then
	echo "ERROR: restore pod did not succeed" >&2
	exit 1
fi
kubectl delete pod "$RESTORE_POD" -n "$PVC_NS"

# On success, remove scaled state so trap skips restore (workloads already handled)
rm -f "$SCALED_FILE"

# Scale workloads back up
for w in $WORKLOADS; do
	wkind="${w%%/*}"
	wname="${w##*/}"
	reps=$(kubectl get "$wkind" "$wname" -n "$PVC_NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
	if [ "$reps" -eq 0 ]; then
		# read original replica count from the deploy/statefulset directly
		original=$(kubectl get "$wkind" "$wname" -n "$PVC_NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
		echo "Scaling $wkind/$wname back to 1..."
		kubectl scale "$wkind" "$wname" -n "$PVC_NS" --replicas=1
	fi
done

echo ""
echo "Restore of $PVC_NAME complete."
