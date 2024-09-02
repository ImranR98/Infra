#!/bin/bash -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
kubectl create -n production secret generic authelia-users --from-file="$HERE"/users-database.yaml
helm install authelia authelia/authelia --values "$HERE"/authelia/values.yaml --namespace production