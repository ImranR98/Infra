#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
helm install cert-manager jetstack/cert-manager --values <(cat "$HERE"/values.yaml | envsubst) --set crds.enabled=true --namespace production
kubectl apply -f <(cat "$HERE"/issuers/secret-cf-token.yaml | envsubst)
kubectl apply -f <(cat "$HERE"/issuers/letsencrypt-staging.yaml | envsubst)
kubectl apply -f <(cat "$HERE"/issuers/letsencrypt-production.yaml | envsubst)
kubectl apply -f <(cat "$HERE"/certificates/production/services.yaml | envsubst)
