#!/bin/bash
# DESC: Mount a Longhorn PVC and a hostPath directory in a temporary pod and drop into a shell
set -euo pipefail

source "$INFRA_ROOT/lib/common.sh"

usage() {
    echo "Usage: $0 <pvc-name> [namespace] [host-path]" >&2
    echo "  pvc-name    Name of the Longhorn PVC to mount at /pvc" >&2
    echo "  namespace   Namespace of the PVC (default: apps)" >&2
    echo "  host-path   Host directory to mount at /host (default: /tmp/pvc-transfer)" >&2
    exit 1
}

PVC="${1:-}"
[ -n "$PVC" ] || usage
NS="${2:-apps}"
HOST_PATH="${3:-/tmp/pvc-transfer}"

# If namespace not specified, try to find it
if [ "${2:-}" = "" ] || [ "$NS" = "apps" ]; then
    found_ns=$(pvc_find_namespace "$PVC")
    if [ -n "$found_ns" ]; then
        NS="$found_ns"
    fi
fi

# Verify the PVC exists and is Longhorn
SC=$(kubectl get pvc "$PVC" -n "$NS" -o jsonpath='{.spec.storageClassName}' 2>/dev/null)
if [ -z "$SC" ]; then
    echo "Error: PVC $PVC not found in namespace $NS" >&2
    exit 1
fi
echo "PVC: $NS/$PVC  StorageClass: $SC  HostPath: $HOST_PATH"

# Ensure host path exists
mkdir -p "$HOST_PATH"

POD_NAME="pvc-shell-$(echo "$PVC" | tr '_' '-' | tr -dc 'a-z0-9-')"

cat <<PODEOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  namespace: $NS
  labels:
    app: pvc-shell-temp
spec:
  restartPolicy: Never
  containers:
  - name: shell
    image: ubuntu:24.04
    stdin: true
    tty: true
    command:
    - bash
    - -c
    - |
      echo "=== PVC Shell ==="
      echo "PVC mounted at: /pvc"
      echo "HostPath mounted at: /host"
      echo ""
      echo "Example commands:"
      echo ""
      echo "  # Sync PVC → Host (backup)"
      echo "  rsync -avh --progress /pvc/ /host/"
      echo ""
      echo "  # Sync Host → PVC (restore)"
      echo "  rsync -avh --progress /host/ /pvc/"
      echo ""
      echo "  # Create tar backup of PVC"
      echo "  tar czf /host/pvc-backup-\$(date +%Y%m%d-%H%M%S).tar.gz -C /pvc ."
      echo ""
      echo "  # Restore tar backup to PVC"
      echo "  tar xzf /host/pvc-backup-*.tar.gz -C /pvc"
      echo ""
      echo "  # Check sizes"
      echo "  du -sh /pvc /host /pvc/* 2>/dev/null | sort -h"
      echo ""
      bash
    securityContext:
      runAsUser: 0
    volumeMounts:
    - name: pvc
      mountPath: /pvc
    - name: host
      mountPath: /host
  volumes:
  - name: pvc
    persistentVolumeClaim:
      claimName: $PVC
  - name: host
    hostPath:
      path: $HOST_PATH
      type: DirectoryOrCreate
PODEOF

echo "Waiting for pod to be ready..."
kubectl wait --for=condition=Ready "pod/$POD_NAME" -n "$NS" --timeout=120s 2>/dev/null

echo ""
echo "Entering shell. Type 'exit' or Ctrl-D when done."
echo "Pod will remain running until you exit — you can exit and re-attach with:"
echo "  kubectl exec -it $POD_NAME -n $NS -- bash"
echo ""

kubectl exec -it "$POD_NAME" -n "$NS" -- bash || true

echo ""
read -r -p "Delete pod $POD_NAME? [Y/n] " confirm
confirm="${confirm:-Y}"
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    kubectl delete pod "$POD_NAME" -n "$NS" --ignore-not-found
    echo "Pod deleted."
else
    echo "Pod $POD_NAME kept. Delete manually with:"
    echo "  kubectl delete pod $POD_NAME -n $NS"
fi
