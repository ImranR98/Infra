#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
helm install cert-manager jetstack/cert-manager --values "$HERE"/values.yaml --set crds.enabled=true --namespace production
kubectl apply -f "$HERE"/issuers/secret-cf-token.yaml
kubectl apply -f "$HERE"/issuers/
kubectl apply -f "$HERE"/certificates/production/
