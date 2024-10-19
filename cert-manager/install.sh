#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HELPERS_PATH"
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager --values <(cat "$HERE"/values.yaml | envsubst) --set crds.enabled=true --namespace production
kubectl apply -f <(cat "$HERE"/issuers/secret-cf-token.yaml | envsubst)
kubectl apply -f <(cat "$HERE"/issuers/letsencrypt-staging.yaml | envsubst)
kubectl apply -f <(cat "$HERE"/issuers/letsencrypt-production.yaml | envsubst)
kubectl apply -f <(cat "$HERE"/certificates/production/services.yaml | envsubst)
kubectl apply -f <(cat "$HERE"/issuers/mtls.yaml | envsubst)
kubectl apply -f <(cat "$HERE"/certificates/mtls.yaml | envsubst)

mkdir -p "$STATE_DIR"/mtls
kubectl get secret mtls-client-secret -n production -o jsonpath='{.data.tls\.crt}' | base64 --decode > "$STATE_DIR"/mtls/mtls-client.crt
kubectl get secret mtls-client-secret -n production -o jsonpath='{.data.tls\.key}' | base64 --decode > "$STATE_DIR"/mtls/mtls-client.key
openssl pkcs12 -export -out "$STATE_DIR"/mtls/mtls-client.p12 -inkey "$STATE_DIR"/mtls/mtls-client.key -in "$STATE_DIR"/mtls/mtls-client.crt

printLine -
echo "NOTE: Run this to keep an eye on pending cert requests:
watch -n 1 kubectl -n production get certificaterequests.cert-manager.io -o wide"
