#!/bin/bash
set -euo pipefail

COMP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
export VARS_ROOT="$(cd "$COMP_DIR/../../../.." >/dev/null 2>&1 && pwd)"
export TARGET="$(basename "$(cd "$COMP_DIR/../.." >/dev/null 2>&1 && pwd)")"
source "$VARS_ROOT/lib/vars.sh"
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
kubectl -n base exec -i "$POD" -- ntfy user add --role=admin --ignore-exists admin 2>/dev/null <<< "$NTFY_ADMIN_PASSWORD" || true
kubectl -n base exec -i "$POD" -- ntfy user add --ignore-exists service 2>/dev/null <<< "$NTFY_ADMIN_PASSWORD" || true
kubectl -n base exec "$POD" -- ntfy access service '*' write-only 2>/dev/null || true

# Create service token if it doesn't exist
if ! kubectl -n base get secret ntfy-service-token >/dev/null 2>&1; then
	TOKEN=$(kubectl -n base exec "$POD" -- ntfy token add service 2>&1 | grep -o 'tk_[^[:space:]]*')
	if [ -n "$TOKEN" ]; then
		for ns in $(kubectl get namespace -l pod-security.kubernetes.io/warn=baseline -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
			kubectl create secret generic ntfy-service-token \
				--namespace "$ns" \
				--from-literal=token="$TOKEN" \
				--dry-run=client -o yaml | kubectl apply -f -
		done
		echo "ntfy service token created and stored in K8s secret 'ntfy-service-token' (all user namespaces)" >&2
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
