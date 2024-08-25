#!/bin/bash -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

DEPLOYMENT_NAME="$1"

if [ -z "$DEPLOYMENT_NAME" ]; then
    echo "Service name not specified!" >&2
    exit 1
fi

NAMESPACE="production"

if [ -f "$HERE"/docker-compose/token ]; then
    TOKEN=$(cat "$HERE"/docker-compose/token)
else
    echo "No token file found!" >&2
    exit 1
fi

if [ -f "$HERE"/docker-compose/ca.crt ]; then
    CA_CERT="$HERE"/docker-compose/ca.crt
else
    echo "No ca.crt file found!" >&2
    exit 1
fi

API_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"

PODS=$(curl -s --header "Authorization: Bearer $TOKEN" \
    --cacert $CA_CERT \
    "$API_SERVER/api/v1/namespaces/$NAMESPACE/pods?labelSelector=k8s-app=$DEPLOYMENT_NAME" |
    jq -r '.items[].metadata.name')

if [ -z "$PODS" ]; then
    PODS=$(curl -s --header "Authorization: Bearer $TOKEN" \
        --cacert $CA_CERT \
        "$API_SERVER/api/v1/namespaces/$NAMESPACE/pods?labelSelector=app.kubernetes.io/name=$DEPLOYMENT_NAME" |
        jq -r '.items[].metadata.name')
fi

for POD in $PODS; do
    curl -s --header "Authorization: Bearer $TOKEN" \
        --cacert $CA_CERT \
        "$API_SERVER/api/v1/namespaces/$NAMESPACE/pods/$POD/log?follow=true" &
done

wait
