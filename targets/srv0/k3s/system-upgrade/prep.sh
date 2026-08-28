#!/bin/bash
set -euo pipefail

source "$INFRA_ROOT/lib/common.sh"

SUC_BASE="https://github.com/rancher/system-upgrade-controller/releases/latest/download"

echo "Applying system-upgrade-controller (latest)..."
kubectl apply -f "$SUC_BASE/crd.yaml"
kubectl apply -f "$SUC_BASE/system-upgrade-controller.yaml"

echo "Waiting for system-upgrade CRDs..."
wait_for_crds 300 plans.upgrade.cattle.io
