#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HELPERS_PATH"
helm uninstall cert-manager --namespace production
kubectl delete -f <(cat "$HERE"/issuers/secret-cf-token.yaml | envsubst)
kubectl delete -f <(cat "$HERE"/issuers/letsencrypt-staging.yaml | envsubst)
kubectl delete -f <(cat "$HERE"/issuers/letsencrypt-production.yaml | envsubst)
kubectl delete -f <(cat "$HERE"/certificates/production/services.yaml | envsubst)