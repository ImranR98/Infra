#!/bin/bash
set -euo pipefail

COMP_DIR="$INFRA_ROOT/targets/$TARGET/k3s/cert-manager"
source "$INFRA_ROOT/lib/common.sh"

echo "Waiting for cert-manager CRDs..."
wait_for_crds 300 certificates.cert-manager.io clusterissuers.cert-manager.io issuers.cert-manager.io

echo "Waiting for cert-manager pod..."
retry 60 5 "kubectl -n base wait --for=condition=Ready pod -l app.kubernetes.io/name=cert-manager --timeout=10s >/dev/null 2>&1"

echo "Waiting for cert-manager-webhook CA injection..."
retry 60 5 "kubectl get validatingwebhookconfiguration cert-manager-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | grep -q ."

echo "Applying issuers..."
retry 30 5 "envsubst \"\$ENVSUBST_VARS\" <\"\$COMP_DIR/issuers.yaml\" | kubectl apply -f -"
retry 30 5 "kubectl get clusterissuer letsencrypt-staging >/dev/null"

echo "Waiting for local CA certificate..."
retry 60 5 "kubectl get certificate k3s-local-ca -n base -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"

echo "Waiting for ca-issuer ClusterIssuer..."
retry 60 5 "kubectl get clusterissuer ca-issuer -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"

echo "Cert-manager: local CA infrastructure ready for Mosquitto."
