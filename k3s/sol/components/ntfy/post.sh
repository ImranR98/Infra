#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/common.sh"
source_env

echo "Waiting for ntfy pod..." >&2
for _ in $(seq 1 300); do
    if kubectl -n base wait --for=condition=Ready pod -l app=ntfy --timeout=10s >/dev/null 2>&1; then
        break
    fi
    sleep 5
done
POD=$(kubectl -n base get pod -l app=ntfy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$POD" ]; then
    echo "Warning: ntfy pod not ready within 300s, skipping post-deploy setup."
    exit 0
fi

# Provision admin and service users
kubectl -n base exec "$POD" -- env NTFY_PASSWORD="$NTFY_ADMIN_PASSWORD" \
	ntfy user add --role=admin --ignore-exists admin 2>/dev/null || true
kubectl -n base exec "$POD" -- env NTFY_PASSWORD="$NTFY_ADMIN_PASSWORD" \
	ntfy user add --ignore-exists service 2>/dev/null || true
kubectl -n base exec "$POD" -- ntfy access service '*' write-only 2>/dev/null || true

# Create service token if it doesn't exist
if ! kubectl -n base get secret ntfy-service-token >/dev/null 2>&1; then
	TOKEN=$(kubectl -n base exec "$POD" -- ntfy token add service 2>&1 | grep -oP 'tk_\S+')
	if [ -n "$TOKEN" ]; then
		for ns in base apps monitoring syncthing; do
			kubectl create secret generic ntfy-service-token \
				--namespace "$ns" \
				--from-literal=token="$TOKEN" \
				--dry-run=client -o yaml | kubectl apply -f -
		done
		echo "ntfy service token created and stored in K8s secret 'ntfy-service-token' (namespaces: base, apps, monitoring, syncthing)" >&2
		echo ""
		echo "*** The token has been distributed to all namespaces. Services that embed   ***"
		echo "*** the token in ConfigMaps/Secrets (crowdsec, logtfy, opencanary) still    ***"
		echo "*** use envsubst from VARS.sh. Update NTFY_SERVICE_USER_TOKEN in VARS.sh     ***"
		echo "*** with the token below, then redeploy those services:                      ***"
		echo "***     make crowdsec && make logtfy && make opencanary                      ***"
		echo "*** Services using secretKeyRef (dscpln, mdscl) pick up the token            ***"
		echo "*** automatically without redeploy.                                          ***"
		echo "*** Token: $TOKEN"
	fi
fi
