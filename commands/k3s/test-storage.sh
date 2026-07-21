#!/bin/bash
# DESC: Smoke-test NFS storage: PV/PVC lifecycle, pod mount, data integrity
set -euo pipefail

NS=base
NAME=storage-test
PV_NAME="${NAME}-pv"
PVC_NAME="${NAME}-pvc"
SIZE=1Gi
TEST_STRING="storage-test-$(date +%s)"
FAILED=false

_fail() { echo "FAIL: $*" >&2; FAILED=true; }
_cleanup() {
    kubectl delete pod -n "$NS" "$NAME" --timeout=30s 2>/dev/null || true
    kubectl delete pvc -n "$NS" "$PVC_NAME" --timeout=30s 2>/dev/null || true
    kubectl delete pv "$PV_NAME" --timeout=30s 2>/dev/null || true
}
trap _cleanup EXIT

echo "=== Create test PV ==="
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $PV_NAME
spec:
  capacity:
    storage: $SIZE
  accessModes:
    - ReadWriteMany
  csi:
    driver: nfs.csi.k8s.io
    volumeHandle: storage-test
    volumeAttributes:
      server: nfs-server.base.svc.cluster.local
      share: /k3s-state
      subDir: storage-test
      mountOptions: nolock
  storageClassName: nfs
  persistentVolumeReclaimPolicy: Retain
EOF

echo "=== Create test PVC ==="
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC_NAME
  namespace: $NS
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: $SIZE
  storageClassName: nfs
  volumeName: $PV_NAME
EOF

echo "=== Wait for PVC bind ==="
kubectl wait -n "$NS" --for=jsonpath='{.status.phase}'=Bound "pvc/$PVC_NAME" --timeout=60s \
  || _fail "PVC did not bind"

echo "=== Create test pod ==="
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $NAME
  namespace: $NS
spec:
  restartPolicy: Never
  containers:
    - name: test
      image: busybox:1.36
      command: ["sh", "-c"]
      args:
        - |
          echo "WRITE: $TEST_STRING" > /mnt/storage-test.txt
          echo "READ:  \$(cat /mnt/storage-test.txt)"
          echo "OK"
      volumeMounts:
        - name: data
          mountPath: /mnt
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: $PVC_NAME
EOF

echo "=== Wait for test pod ==="
kubectl wait -n "$NS" --for=jsonpath='{.status.phase}'=Succeeded "pod/$NAME" --timeout=60s \
  || _fail "Test pod did not succeed"

echo "=== Pod output ==="
POD_OUT=$(kubectl logs -n "$NS" "$NAME" 2>/dev/null)
echo "$POD_OUT"
echo "$POD_OUT" | grep -q "$TEST_STRING" || _fail "Data mismatch"

echo "=== Clean up ==="
kubectl delete pod -n "$NS" "$NAME" --timeout=30s 2>/dev/null || true
kubectl delete pvc -n "$NS" "$PVC_NAME" --timeout=30s 2>/dev/null || true
kubectl delete pv "$PV_NAME" --timeout=30s 2>/dev/null || true

if $FAILED; then
    echo "Some checks failed." >&2
    exit 1
fi

echo "All checks passed."
