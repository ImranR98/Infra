#!/bin/bash
set -euo pipefail

# Fallback derivations — atlas.sh exports these before calling us,
# so they're only computed here when the script is invoked directly.
: ${ATLAS_ROOT:="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"}
: ${TARGET:="sol"}

COMPONENT="$1"
MODE="${2:-apply}"

case "$MODE" in
	apply|initial|delete|diff|yaml) ;;
	*)
		echo "Error: Unknown APPLY_MODE '$MODE'. Valid modes: apply, initial, delete, diff, yaml" >&2
		exit 1
		;;
esac

COMPONENT_DIR="$ATLAS_ROOT/targets/$TARGET/k3s/$COMPONENT"

if [ ! -d "$COMPONENT_DIR" ]; then
	echo "Error: Unknown component '$COMPONENT'" >&2
	exit 1
fi

source "$ATLAS_ROOT/lib/common.sh"
source_env
ENVSUBST_VARS="$(get_envsubst_vars)"

# Auto-detect K3s API server host IP for network policy ipBlock rules.
# kube-proxy DNAT rewrites ClusterIP targets to backend host IPs before
# policy evaluation, so policies must allow the post-NAT destination.
# Uses the /24 subnet so IP changes within the same network segment
# don't require a re-apply.
_k8s_api_ip="$(kubectl get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)"
export K8S_API_SERVER_IP="${K8S_API_SERVER_IP:-$_k8s_api_ip}"
export K8S_API_SERVER_SUBNET="${K8S_API_SERVER_SUBNET:-${_k8s_api_ip%.*}.0/24}"
ENVSUBST_VARS="$ENVSUBST_VARS"'$K8S_API_SERVER_IP $K8S_API_SERVER_SUBNET'

if [[ ("$MODE" == "apply" || "$MODE" == "initial") && -f "$COMPONENT_DIR/prep.sh" ]]; then
	source "$COMPONENT_DIR/prep.sh"
fi

if [ "$MODE" = "apply" ]; then
	_HAS_INITIAL_RESOURCES=""
	grep -q '# IGNORE INITIALLY$' "$COMPONENT_DIR"/*.yaml 2>/dev/null && _HAS_INITIAL_RESOURCES=1
	if [ -n "$_HAS_INITIAL_RESOURCES" ]; then
		_MISSING_STATE=""
		kubectl get crd certificates.cert-manager.io >/dev/null 2>&1 || _MISSING_STATE="$_MISSING_STATE  - cert-manager CRDs\n"
		kubectl get ns longhorn-system >/dev/null 2>&1 || _MISSING_STATE="$_MISSING_STATE  - longhorn-system namespace\n"
		if [ -n "$_MISSING_STATE" ]; then
			printf '\n\033[1;33m╔══════════════════════════════════════════════════════════════╗\n'
			printf     '║  WARNING: This cluster may not be fully initialized.        ║\n'
			printf     '║  The following expected prerequisites are missing:          ║\n'
			printf     '║                                                            ║\n'
			printf "$_MISSING_STATE"
			printf     '║                                                            ║\n'
			printf     '║  If this is a fresh install, run with APPLY_MODE=initial    ║\n'
			printf     '║  first, then re-run without it.                             ║\n'
			printf     '╚══════════════════════════════════════════════════════════════╝\033[0m\n\n'
			if [ -t 0 ]; then
				read -rp "Press Enter to continue anyway, or Ctrl-C to abort... "
			else
				echo "Non-interactive mode: continuing automatically..."
			fi
		fi
	fi
fi

if [ "$MODE" = "initial" ] && [ -f "$COMPONENT_DIR/kustomization.yaml" ]; then
	TMP_DIR=$(mktemp -d)
	trap "rm -rf '$TMP_DIR'" EXIT
	for f in "$COMPONENT_DIR"/*.yaml; do
		sed '/# IGNORE INITIALLY$/d' "$f" > "$TMP_DIR/$(basename "$f")"
	done
	RAW_YAML=$(kubectl kustomize "$TMP_DIR")
else
	RAW_YAML=$(kubectl kustomize "$COMPONENT_DIR")
fi

PROCESSED_YAML=$(printf '%s\n' "$RAW_YAML" | envsubst "$ENVSUBST_VARS")

if [ "$MODE" = "delete" ]; then
	[ -f "$COMPONENT_DIR/delete.sh" ] && bash "$COMPONENT_DIR/delete.sh"

	_YAML=$(printf '%s\n' "$PROCESSED_YAML")

	# ── Phase 1: Delete HelmCharts first, wait for helm-delete jobs ──────────
	# Helm releases need to cleanly destroy their pods/services/secrets before
	# we touch anything else. The HelmChart API object stays alive until the
	# helm-delete-* job completes, so we wait for the chart resource itself to
	# vanish — that confirms the cleanup job ran to completion.
	_helmcharts=$(printf '%s\n' "$_YAML" | yq -r 'select(.kind == "HelmChart") | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null | sed '/^---$/d')
	if [ -n "$_helmcharts" ]; then
		while IFS="/" read -r ns chart; do
			[ -z "$chart" ] && continue
			echo "Deleting HelmChart $ns/$chart..."
			kubectl delete helmchart "$chart" -n "$ns" --wait=false 2>/dev/null || true
			if ! kubectl wait --for=delete helmchart "$chart" -n "$ns" --timeout=30s >/dev/null 2>&1; then
				echo "" >&2
				echo "╔══════════════════════════════════════════════════════════════╗" >&2
				echo "║  ERROR: HelmChart $ns/$chart did not finish deleting  ║" >&2
				echo "║  within 30s. The helm-delete job likely failed.              ║" >&2
				echo "║  Check logs:                                                 ║" >&2
				echo "║    kubectl logs -n $ns -l job-name=helm-delete-$chart       ║" >&2
				echo "║  Common causes: egress policy blocking the job, chart        ║" >&2
				echo "║  repo unreachable, or the Helm release is in a broken        ║" >&2
				echo "║  state. Delete the release manually if needed:               ║" >&2
				echo "║    helm delete $chart -n $ns                                ║" >&2
				echo "╚══════════════════════════════════════════════════════════════╝" >&2
				exit 1
			fi
		done <<< "$_helmcharts"
	fi

	# ── Phase 2: Delete everything except PVCs ───────────────────────────────
	# Deployments, services, secrets, configmaps, etc. delete quickly. We wait
	# so kubectl confirms each resource is gone. If something can't delete
	# (e.g. a deployment with a stuck finalizer), kubectl exits non-zero and
	# we bail immediately.
	printf '%s\n' "$_YAML" | yq 'select(.kind != "PersistentVolumeClaim")' 2>/dev/null | kubectl delete --wait -f - 2>/dev/null || {
		echo "Deletion of some non-PVC resources failed. Check output above." >&2
	}

	# ── Phase 3: Delete PVCs, wait with diagnostics ──────────────────────────
	# PVCs are separated because they're the only resource that predictably
	# gets stuck — the CSI driver finalizer can't be removed if the storage
	# backend (Longhorn/NFS) has already been deleted out of order.
	_pvcs=$(printf '%s\n' "$_YAML" | yq -r 'select(.kind == "PersistentVolumeClaim") | .metadata.namespace + "/" + .metadata.name' 2>/dev/null | sed '/^---$/d')
	if [ -n "$_pvcs" ]; then
		while IFS="/" read -r ns pvc_name; do
			[ -z "$pvc_name" ] && continue
			echo "Deleting PVC $ns/$pvc_name..."
			kubectl delete pvc "$pvc_name" -n "$ns" --wait=false 2>/dev/null || true
			if ! kubectl wait --for=delete pvc "$pvc_name" -n "$ns" --timeout=30s >/dev/null 2>&1; then
				echo "" >&2
				echo "╔══════════════════════════════════════════════════════════════╗" >&2
				echo "║  ERROR: PVC $ns/$pvc_name did not finish deleting   ║" >&2
				echo "║  within 30s. The CSI driver or storage backend needed       ║" >&2
				echo "║  to release it may already be deleted.                      ║" >&2
				echo "║  Check what's holding the finalizer:                        ║" >&2
				echo "║    kubectl describe pvc $pvc_name -n $ns | grep Finalizers  ║" >&2
				echo "║  If the storage backend is gone, strip the finalizer:       ║" >&2
				echo "║    kubectl patch pvc $pvc_name -n $ns -p '{\"metadata\":{\"finalizers\":null}}' --type=merge  ║" >&2
				echo "║  Or re-install the storage backend (Longhorn/NFS) first.    ║" >&2
				echo "╚══════════════════════════════════════════════════════════════╝" >&2
				exit 1
			fi

			# Phase 4: Clear claimRef.uid on Released PVs so new PVCs can re-bind
			kubectl get pv -o json 2>/dev/null | jq -r ".items[] | select(.status.phase == \"Released\" and .spec.claimRef.name == \"$pvc_name\" and .spec.claimRef.namespace == \"$ns\") | .metadata.name" | while read -r pv; do
				kubectl patch pv "$pv" --type=json -p='[{"op": "remove", "path": "/spec/claimRef/uid"}]' 2>/dev/null || true
			done
		done <<< "$_pvcs"
	fi
elif [ "$MODE" = "diff" ]; then
	printf '%s\n' "$PROCESSED_YAML" | kubectl diff -f - || true
elif [ "$MODE" = "yaml" ]; then
	printf '%s\n' "$PROCESSED_YAML"
else
	_retries=0
	while true; do
		if output=$(printf '%s\n' "$PROCESSED_YAML" | kubectl apply -f - 2>&1); then
			echo "$output" | grep -v '^$' || true
			break
		fi
		if echo "$output" | grep -qiE "connection refused|no route to host|i/o timeout"; then
			_retries=$((_retries + 1))
			if [ $_retries -ge 12 ]; then
				echo "Error: Transient API error after 12 retries. Aborting." >&2
				exit 1
			fi
			echo "Warning: API temporarily unavailable. Retrying in 10s..."
			sleep 10
			continue
		fi
		echo "Error: Apply failed." >&2
		echo "$output" >&2
		exit 1
	done
fi

if [[ ("$MODE" == "apply" || "$MODE" == "initial") && -f "$COMPONENT_DIR/post.sh" ]]; then
	bash "$COMPONENT_DIR/post.sh"
fi

if [ "$MODE" = "initial" ]; then
	if [ -f "$COMPONENT_DIR/kustomization.yaml" ] && grep -q '# IGNORE INITIALLY$' "$COMPONENT_DIR"/*.yaml 2>/dev/null; then
		printf '\n\033[1;33m╔══════════════════════════════════════════════════════════════╗\n'
		printf     '║  REMINDER: This deployment ran with APPLY_MODE=initial.     ║\n'
		printf     '║  Some resources were skipped (e.g. certs, policies that     ║\n'
		printf     '║  depend on infrastructure not yet available).               ║\n'
		printf     '║                                                            ║\n'
		printf     '║  Re-run without APPLY_MODE=initial once prerequisites       ║\n'
		printf     '║  are ready to complete the full deployment.                 ║\n'
		printf     '╚══════════════════════════════════════════════════════════════╝\033[0m\n\n'
	fi
fi
