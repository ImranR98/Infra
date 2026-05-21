#!/bin/bash
set -euo pipefail

COMP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
export VARS_ROOT="$(cd "$COMP_DIR/../../../.." >/dev/null 2>&1 && pwd)"
export TARGET="$(basename "$(cd "$COMP_DIR/../.." >/dev/null 2>&1 && pwd)")"
source "$VARS_ROOT/lib/vars.sh"
source_env

echo "Waiting for cert-manager CRDs..."
for crd in certificates.cert-manager.io clusterissuers.cert-manager.io issuers.cert-manager.io; do
    until kubectl wait --for condition=established "crd/$crd" --timeout=10s 2>/dev/null; do
        sleep 5
    done
done

echo "Waiting for cert-manager pod..."
until kubectl -n base wait --for=condition=Ready pod -l app.kubernetes.io/name=cert-manager --timeout=10s >/dev/null 2>&1; do
    sleep 5
done

echo "Waiting for cert-manager-webhook CA injection..."
until kubectl get validatingwebhookconfiguration cert-manager-webhook \
    -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null | grep -q .; do
    sleep 5
done

echo "Applying issuers..."
ENVSUBST_VARS="$(get_envsubst_vars)"
until envsubst "$ENVSUBST_VARS" <"$COMP_DIR/issuers.yaml" | kubectl apply -f - 2>/dev/null; do
    sleep 5
done

until kubectl get clusterissuer letsencrypt-staging >/dev/null 2>&1; do sleep 5; done
