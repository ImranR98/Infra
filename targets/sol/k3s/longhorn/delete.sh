#!/bin/bash
# Teardown Longhorn operator resources before kubectl delete handles
# the HelmChart. Longhorn's admission webhooks + CRD finalizers create
# a circular dependency: the webhook service disappears before CRD
# resources can be cleaned up, causing helm uninstall --wait to hang.
# We break the cycle by manually stripping finalizers and removing
# webhooks first.
set -euo pipefail

COMP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
: ${ATLAS_ROOT:="$(cd "$COMP_DIR/../../../.." >/dev/null 2>&1 && pwd)"}
: ${TARGET:="sol"}
source "$ATLAS_ROOT/lib/common.sh"

NS=longhorn-system

echo "Scaling down Longhorn controllers..."
kubectl scale deployment longhorn-manager -n "$NS" --replicas=0 --timeout=10s 2>/dev/null || true
kubectl scale deployment longhorn-driver-deployer -n "$NS" --replicas=0 --timeout=10s 2>/dev/null || true

echo "Deleting Longhorn custom resources..."
for crd in $(kubectl api-resources --api-group=longhorn.io -o name --namespaced 2>/dev/null); do
	kubectl delete "$crd" --all -n "$NS" --wait=false --ignore-not-found 2>/dev/null || true
done

echo "Stripping longhorn.io finalizers from stuck resources..."
for crd in $(kubectl api-resources --api-group=longhorn.io -o name --namespaced 2>/dev/null); do
	crd_short="${crd#*.}"  # strip group prefix (e.g. "volumes.longhorn.io" → "volumes")
	[ -z "$crd_short" ] && crd_short="$crd"
	kubectl get "$crd" -n "$NS" -o name --ignore-not-found 2>/dev/null | while read -r obj; do
		kubectl patch "$obj" -n "$NS" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
	done
done

echo "Removing admission webhooks..."
kubectl delete validatingwebhookconfiguration longhorn-webhook-validator --ignore-not-found 2>/dev/null || true
kubectl delete mutatingwebhookconfiguration longhorn-webhook-mutator --ignore-not-found 2>/dev/null || true

echo "Removing longhorn.io finalizers from PVs..."
kubectl get pv -o name --ignore-not-found 2>/dev/null | while read -r pv; do
	kubectl patch "$pv" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
done

echo "Deleting longhorn-system namespace..."
kubectl delete ns longhorn-system --wait=false --ignore-not-found 2>/dev/null || true

echo "Longhorn pre-delete cleanup complete."
