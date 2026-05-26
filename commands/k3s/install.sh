#!/bin/bash
set -euo pipefail

: ${TARGET:="sol"}

COMPONENT="$1"
MODE="${2:-apply}"

COMPONENT_DIR="$ATLAS_ROOT/targets/$TARGET/k3s/$COMPONENT"

if [ ! -d "$COMPONENT_DIR" ]; then
	echo "Error: Unknown component '$COMPONENT'" >&2
	exit 1
fi

source "$ATLAS_ROOT/lib/common.sh"
source_env
ensure_envsubst_vars

_k8s_api_ip="$(kubectl get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)"
export K8S_API_SERVER_IP="${K8S_API_SERVER_IP:-$_k8s_api_ip}"
export K8S_API_SERVER_SUBNET="${K8S_API_SERVER_SUBNET:-${_k8s_api_ip%.*}.0/24}"
ENVSUBST_VARS="$ENVSUBST_VARS"'$K8S_API_SERVER_IP $K8S_API_SERVER_SUBNET'

_has_initial_markers=false
grep -q '# IGNORE INITIALLY$' "$COMPONENT_DIR"/*.yaml 2>/dev/null && _has_initial_markers=true

_build_yaml() {
	local is_initial="${1:-false}"
	if [ "$is_initial" = true ] && [ -f "$COMPONENT_DIR/kustomization.yaml" ]; then
		TMP_DIR=$(mktemp -d)
		_cleanup_dirs+=("$TMP_DIR")
		for f in "$COMPONENT_DIR"/*.yaml; do
			sed '/# IGNORE INITIALLY$/d' "$f" > "$TMP_DIR/$(basename "$f")"
		done
		RAW_YAML=$(kubectl kustomize "$TMP_DIR")
	else
		RAW_YAML=$(kubectl kustomize "$COMPONENT_DIR")
	fi
	PROCESSED_YAML=$(printf '%s\n' "$RAW_YAML" | envsubst "$ENVSUBST_VARS")
}

_run_hook() {
	local hook="$1"
	if [ -f "$COMPONENT_DIR/$hook" ]; then
		bash "$COMPONENT_DIR/$hook"
	fi
}

_check_initial_prereqs() {
	if ! $_has_initial_markers; then
		return
	fi

	_MISSING_STATE=""
	kubectl get crd certificates.cert-manager.io >/dev/null 2>&1 || _MISSING_STATE="$_MISSING_STATE  - cert-manager CRDs\n"
	kubectl get ns longhorn-system >/dev/null 2>&1 || _MISSING_STATE="$_MISSING_STATE  - longhorn-system namespace\n"
	if [ -z "$_MISSING_STATE" ]; then
		return
	fi

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
}

_initial_reminder() {
	if [ ! -f "$COMPONENT_DIR/kustomization.yaml" ]; then
		return
	fi
	if ! $_has_initial_markers; then
		return
	fi
	printf '\n\033[1;33m╔══════════════════════════════════════════════════════════════╗\n'
	printf     '║  REMINDER: This deployment ran with APPLY_MODE=initial.     ║\n'
	printf     '║  Some resources were skipped (e.g. certs, policies that     ║\n'
	printf     '║  depend on infrastructure not yet available).               ║\n'
	printf     '║                                                            ║\n'
	printf     '║  Re-run without APPLY_MODE=initial once prerequisites       ║\n'
	printf     '║  are ready to complete the full deployment.                 ║\n'
	printf     '╚══════════════════════════════════════════════════════════════╝\033[0m\n\n'
}

_k3s_apply() {
	local _retries=0
	while true; do
		local output
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
}

_delete_resource_with_timeout() {
	local kind="$1" ns="$2" name="$3" timeout="${4:-30s}"
	kubectl delete "$kind" "$name" -n "$ns" --wait=false 2>/dev/null || true
	if ! kubectl wait --for=delete "$kind" "$name" -n "$ns" --timeout="$timeout" >/dev/null 2>&1; then
		local suggestion
		case "$kind" in
			helmchart)
				suggestion="Check logs:
    kubectl logs -n $ns -l job-name=helm-delete-$name
  Common causes: egress policy blocking the job, chart
  repo unreachable, or the Helm release is in a broken
  state. Delete the release manually if needed:
    helm delete $name -n $ns" ;;
			pvc)
				suggestion="Check what's holding the finalizer:
    kubectl describe pvc $name -n $ns | grep Finalizers
  If the storage backend is gone, strip the finalizer:
    kubectl patch pvc $name -n $ns -p '{\"metadata\":{\"finalizers\":null}}' --type=merge
  Or re-install the storage backend (Longhorn/NFS) first." ;;
			*) suggestion="" ;;
		esac
		echo "" >&2
		printf '╔══════════════════════════════════════════════════════════════╗\n' >&2
		printf "║  ERROR: %s %s/%s did not finish deleting within %s.  ║\n" "$kind" "$ns" "$name" "$timeout" >&2
		printf '║  %s  ║\n' "$suggestion" >&2
		printf '╚══════════════════════════════════════════════════════════════╝\n' >&2
		exit 1
	fi
}

_k3s_delete() {
	[ -f "$COMPONENT_DIR/delete.sh" ] && bash "$COMPONENT_DIR/delete.sh"

	local _YAML; _YAML=$(printf '%s\n' "$PROCESSED_YAML")

	local _helmcharts
	_helmcharts=$(printf '%s\n' "$_YAML" | yq -r 'select(.kind == "HelmChart") | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null | sed '/^---$/d')
	if [ -n "$_helmcharts" ]; then
		while IFS="/" read -r ns chart; do
			[ -z "$chart" ] && continue
			echo "Deleting HelmChart $ns/$chart..."
			_delete_resource_with_timeout helmchart "$ns" "$chart"
		done <<< "$_helmcharts"
	fi

	printf '%s\n' "$_YAML" | yq 'select(.kind != "PersistentVolumeClaim")' 2>/dev/null | kubectl delete --wait -f - 2>/dev/null || {
		echo "Deletion of some non-PVC resources failed. Check output above." >&2
	}

	local _pvcs
	_pvcs=$(printf '%s\n' "$_YAML" | yq -r 'select(.kind == "PersistentVolumeClaim") | .metadata.namespace + "/" + .metadata.name' 2>/dev/null | sed '/^---$/d')
	if [ -n "$_pvcs" ]; then
		while IFS="/" read -r ns pvc_name; do
			[ -z "$pvc_name" ] && continue
			echo "Deleting PVC $ns/$pvc_name..."
			_delete_resource_with_timeout pvc "$ns" "$pvc_name"
			kubectl get pv -o json 2>/dev/null | jq -r ".items[] | select(.status.phase == \"Released\" and .spec.claimRef.name == \"$pvc_name\" and .spec.claimRef.namespace == \"$ns\") | .metadata.name" | while read -r pv; do
				kubectl patch pv "$pv" --type=json -p='[{"op": "remove", "path": "/spec/claimRef/uid"}]' 2>/dev/null || true
			done
		done <<< "$_pvcs"
	fi
}

_k3s_diff() {
	printf '%s\n' "$PROCESSED_YAML" | kubectl diff -f - || true
}

_k3s_yaml() {
	printf '%s\n' "$PROCESSED_YAML"
}

trap 'rm -rf "${_cleanup_dirs[@]:-}"' EXIT
declare -a _cleanup_dirs=()

case "$MODE" in
	apply)
		_run_hook prep.sh
		_check_initial_prereqs
		_build_yaml false
		_k3s_apply
		_run_hook post.sh
		;;
	initial)
		_run_hook prep.sh
		_build_yaml true
		_k3s_apply
		_run_hook post.sh
		_initial_reminder
		;;
	delete)
		_build_yaml false
		_k3s_delete
		;;
	diff)
		_build_yaml false
		_k3s_diff
		;;
	yaml)
		_build_yaml false
		_k3s_yaml
		;;
	*)
		echo "Error: Unknown mode '$MODE'. Valid modes: apply, initial, delete, diff, yaml" >&2
		exit 1
		;;
esac