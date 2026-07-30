#!/bin/bash
set -euo pipefail

# Create the MaxMind credentials Secret directly (bypass kustomize, which
# strips YAML quotes and causes numeric account IDs to be rejected by the
# Kubernetes Secret validation).
kubectl -n base apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: geoipupdate-secret
  namespace: base
type: Opaque
stringData:
  account-id: "$GEOIPUPDATE_ACCOUNT_ID"
  license-key: "$GEOIPUPDATE_LICENSE_KEY"
EOF

# Seed the initial GeoLite2 database so the pod immediately becomes ready.
echo "=== Seeding initial GeoLite2 database ==="
kubectl -n base delete job geoipupdate-init 2>/dev/null || true
kubectl -n base create job --from=cronjob/geoipupdate geoipupdate-init
kubectl -n base wait --for=condition=complete job/geoipupdate-init --timeout=120s
kubectl -n base delete job geoipupdate-init 2>/dev/null || true

echo "=== Waiting for geoip pod to become ready ==="
kubectl -n base wait --for=condition=ready pod -l app=geoip-service --timeout=60s
