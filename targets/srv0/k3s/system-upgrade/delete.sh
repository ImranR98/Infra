#!/bin/bash
set -euo pipefail

source "$INFRA_ROOT/lib/common.sh"

SUC_BASE="https://github.com/rancher/system-upgrade-controller/releases/latest/download"

echo "Deleting system-upgrade plans..."
kubectl delete -n system-upgrade plan --all --ignore-not-found 2>/dev/null || true

echo "Deleting system-upgrade-controller..."
kubectl delete -f "$SUC_BASE/system-upgrade-controller.yaml" --ignore-not-found 2>/dev/null || true
kubectl delete -f "$SUC_BASE/crd.yaml" --ignore-not-found 2>/dev/null || true
