#!/bin/bash
set -euo pipefail

COMP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$ATLAS_ROOT/lib/common.sh"

echo "Waiting for cert-manager CRDs..."
wait_for_crds 300 certificates.cert-manager.io clusterissuers.cert-manager.io issuers.cert-manager.io

echo "Waiting for cert-manager pod..."
for _ in $(seq 1 60); do
	kubectl -n base wait --for=condition=Ready pod -l app.kubernetes.io/name=cert-manager --timeout=10s >/dev/null 2>&1 && break
	sleep 5
done

echo "Waiting for cert-manager-webhook CA injection..."
for _ in $(seq 1 60); do
	kubectl get validatingwebhookconfiguration cert-manager-webhook \
		-o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null | grep -q . && break
	sleep 5
done

echo "Applying issuers..."
ensure_envsubst_vars
for _ in $(seq 1 30); do
	envsubst "$ENVSUBST_VARS" <"$COMP_DIR/issuers.yaml" | kubectl apply -f - 2>/dev/null && break
	sleep 5
done

for _ in $(seq 1 30); do
	kubectl get clusterissuer letsencrypt-staging >/dev/null 2>&1 && break
	sleep 5
done
