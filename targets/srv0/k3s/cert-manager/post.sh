#!/bin/bash
# DESC: Wait for cert-manager CRDs, apply issuers and certificates
set -euo pipefail

COMP_DIR="$ATLAS_ROOT/targets/$TARGET/k3s/cert-manager"
source "$ATLAS_ROOT/lib/common.sh"

echo "Waiting for cert-manager CRDs..."
wait_for_crds 300 certificates.cert-manager.io clusterissuers.cert-manager.io issuers.cert-manager.io

echo "Waiting for cert-manager pod..."
retry 60 5 "kubectl -n base wait --for=condition=Ready pod -l app.kubernetes.io/name=cert-manager --timeout=10s >/dev/null 2>&1"

echo "Waiting for cert-manager-webhook CA injection..."
retry 60 5 "kubectl get validatingwebhookconfiguration cert-manager-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | grep -q ."

echo "Applying issuers..."
ensure_envsubst_vars
retry 30 5 "envsubst \"\$ENVSUBST_VARS\" <\"\$COMP_DIR/issuers.yaml\" | kubectl apply -f -"
retry 30 5 "kubectl get clusterissuer letsencrypt-staging >/dev/null"

echo "Applying certificates..."
retry 30 5 "envsubst \"\$ENVSUBST_VARS\" <\"\$COMP_DIR/certificates.yaml\" | kubectl apply -f -"
