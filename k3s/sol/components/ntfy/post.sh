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

# Create service token
if ! kubectl -n base get secret ntfy-service-token >/dev/null 2>&1; then
	TOKEN=$(kubectl -n base exec "$POD" -- ntfy token add service 2>&1 | grep -oP 'tk_\S+')
	if [ -n "$TOKEN" ]; then
		kubectl -n base create secret generic ntfy-service-token --from-literal=token="$TOKEN"
		echo "ntfy service token: $TOKEN"
		VARS_FILE="$ROOT_DIR/../../VARS.sh"
		if grep -q "^export NTFY_SERVICE_USER_TOKEN=" "$VARS_FILE" 2>/dev/null; then
			sed -i "s|^export NTFY_SERVICE_USER_TOKEN=.*|export NTFY_SERVICE_USER_TOKEN=\"$TOKEN\"|" "$VARS_FILE"
		else
			echo "export NTFY_SERVICE_USER_TOKEN=\"$TOKEN\"" >>"$VARS_FILE"
		fi
		echo ""
		echo "*** IMPORTANT: VARS.sh has been updated with the ntfy service token. ***"
		echo "*** You must manually re-deploy services that rely on this token:    ***"
		echo "***     make logtfy && make dscpln && make mdscl    ***"
	fi
fi
