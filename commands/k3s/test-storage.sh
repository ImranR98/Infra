#!/bin/bash
# DESC: Smoke-test Mayastor storage: pool health, PVC lifecycle, data integrity
set -euo pipefail

FAILED=false

fail() { echo "FAIL: $*" >&2; FAILED=true; }

echo "=== Pool health ==="
kubectl get dsp -n openebs -o wide 2>/dev/null | grep -q "Online.*Healthy" \
  || fail "No Online/Healthy pool found"

echo "=== PVC binding ==="
UNBOUND=$(kubectl get pvc -A --no-headers 2>/dev/null | grep mayastor | grep -cv Bound || true)
if [ "${UNBOUND:-0}" -gt 0 ]; then
  fail "$UNBOUND Mayastor PVCs not Bound"
fi

echo "=== StorageClass ==="
kubectl get sc mayastor-install-single-replica >/dev/null 2>&1 \
  || fail "StorageClass mayastor-install-single-replica not found"

echo "=== Create test PVC ==="
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: storage-test
  namespace: base
spec:
  storageClassName: mayastor-install-single-replica
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

echo "=== Wait for PVC bind ==="
kubectl wait -n base --for=jsonpath='{.status.phase}'=Bound pvc/storage-test --timeout=120s \
  || fail "PVC storage-test did not bind within 120s"

echo "=== Create test pod ==="
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: storage-test
  namespace: base
spec:
  restartPolicy: Never
  containers:
    - name: test
      image: busybox:1.36
      command: ["sh", "-c"]
      args:
        - |
          echo "WRITE: $(date)" > /mnt/test.txt
          echo "READ:  $(cat /mnt/test.txt)"
          echo "OK"
      volumeMounts:
        - name: data
          mountPath: /mnt
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: storage-test
EOF

echo "=== Wait for test pod ==="
kubectl wait -n base --for=jsonpath='{.status.phase}'=Succeeded pod/storage-test --timeout=120s \
  || fail "Test pod did not succeed within 120s"

echo "=== Pod output ==="
POD_OUT=$(kubectl logs -n base storage-test 2>/dev/null)
echo "$POD_OUT"
echo "$POD_OUT" | grep -q "OK" \
  || fail "Test pod did not produce expected output"

echo "=== Clean up ==="
kubectl delete pod -n base storage-test --timeout=30s 2>/dev/null || true
kubectl delete pvc -n base storage-test --timeout=30s 2>/dev/null || true

echo "=== Mayastor pods ==="
UNHEALTHY=$(kubectl get pods -n openebs --no-headers 2>/dev/null | grep -cv -E "Running|Completed" || true)
if [ "${UNHEALTHY:-0}" -gt 0 ]; then
  fail "$UNHEALTHY Mayastor pods not Running/Completed"
fi

if $FAILED; then
  echo "Some checks failed." >&2
  exit 1
fi

echo "All checks passed."
