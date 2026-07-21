#!/bin/bash
# DESC: Deploy, delete, diff, or render a single K3s component
set -euo pipefail

COMPONENT="${1:-}"
MODE="${2:-apply}"

if [ -z "$COMPONENT" ]; then
	echo "Error: No component specified." >&2
	echo "Usage: $0 <component> [mode]" >&2
	echo "Available components:" >&2
	for d in "$ATLAS_ROOT/targets/$TARGET/k3s"/*/; do
		[ -d "$d" ] || continue
		printf '  %s\n' "$(basename "$d")"
	done
	exit 1
fi

COMPONENT_DIR="$ATLAS_ROOT/targets/$TARGET/k3s/$COMPONENT"

if [ ! -d "$COMPONENT_DIR" ]; then
	echo "Error: Unknown component '$COMPONENT'" >&2
	exit 1
fi

source "$ATLAS_ROOT/lib/common.sh"
source_env
ensure_envsubst_vars

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
	# kustomize strips YAML quotes from scalars, so after envsubst numeric
	# vars (e.g. $DSCPLN_BUDGET_INIT_AMT=3000) become bare YAML integers.
	# Kubernetes rejects integer values in env[].value string fields.
	# The sed re-quotes bare numeric values in 'value:' lines.
	#
	# envsubst replaces multiline variables inline only on their first
	# line of occurrence, so subsequent lines inside YAML block scalars
	# (after :| or :|-) lose template indentation.  The awk pass fixes
	# those continuation lines back to the block's base indent.
	PROCESSED_YAML=$(printf '%s\n' "$RAW_YAML" \
		| envsubst "$ENVSUBST_VARS" \
		| sed -E 's/^(\s+value: )([+-]?[0-9]+)$/\1"\2"/' \
		| awk '
			function indent(s) { match(s,/^ */); return RLENGTH }
			/:[[:blank:]]*\|-?[[:blank:]]*$/ { ki=indent($0); blk=1; base=0; got=0; print; next }
			blk && !got && NF>0             { base=indent($0); got=1; print; next }
			blk && NF==0                    { blk=0; print; next }
			blk && (/^---/ || /^\.\.\./)    { blk=0; print; next }
			blk && indent($0)==0 && NF>0    { $0=sprintf("%*s%s",base,"",$0); print; next }
			{ blk=0; print }
		')
}

_run_hook() {
	local hook="$1"
	if [ -f "$COMPONENT_DIR/$hook" ]; then bash "$COMPONENT_DIR/$hook"; fi
}

_check_initial_prereqs() {
	$_has_initial_markers || return 0
	kubectl get crd certificates.cert-manager.io >/dev/null 2>&1 && return 0
	echo "WARNING: cert-manager CRDs not yet available. Run with 'initial' first if this is a fresh install." >&2
}

_initial_reminder() {
	$_has_initial_markers || return 0
	[ -f "$COMPONENT_DIR/kustomization.yaml" ] || return 0
	echo "REMINDER: Re-run without 'initial' once prerequisites are ready to complete deployment." >&2
}

_k3s_apply() {
	printf '%s\n' "$PROCESSED_YAML" | kubectl apply -f -
}

_delete_resource_with_timeout() {
	local kind="$1" ns="$2" name="$3" timeout="${4:-30s}"
	kubectl delete "$kind" "$name" -n "$ns" --wait=false 2>/dev/null || true
	kubectl get "$kind" "$name" -n "$ns" >/dev/null 2>&1 || return 0
	kubectl wait --for=delete "$kind" "$name" -n "$ns" --timeout="$timeout" >/dev/null 2>&1 && return 0
	echo "ERROR: $kind $ns/$name did not finish deleting within $timeout" >&2
	exit 1
}

_k3s_delete() {
	if [ -f "$COMPONENT_DIR/delete.sh" ]; then bash "$COMPONENT_DIR/delete.sh"; fi

	local _YAML; _YAML=$(printf '%s\n' "$PROCESSED_YAML")

	local _helmcharts
	_helmcharts=$(printf '%s\n' "$_YAML" | yq 'select(.kind == "HelmChart") | .metadata.namespace + "/" + .metadata.name' 2>/dev/null)
	if [ -n "$_helmcharts" ]; then
		while IFS="/" read -r ns chart; do
			if [ -z "$chart" ]; then continue; fi
			echo "Deleting HelmChart $ns/$chart..."
			_delete_resource_with_timeout helmchart "$ns" "$chart"
		done <<< "$_helmcharts"
	fi

	printf '%s\n' "$_YAML" | yq 'select(.kind != "PersistentVolumeClaim")' 2>/dev/null | kubectl delete --wait -f - 2>/dev/null || true

	local _pvcs
	_pvcs=$(printf '%s\n' "$_YAML" | yq 'select(.kind == "PersistentVolumeClaim") | .metadata.namespace + "/" + .metadata.name' 2>/dev/null)
	if [ -n "$_pvcs" ]; then
		while IFS="/" read -r ns pvc_name; do
			if [ -z "$pvc_name" ]; then continue; fi
			echo "Deleting PVC $ns/$pvc_name..."
			_delete_resource_with_timeout pvc "$ns" "$pvc_name"
			kubectl get pv -o json 2>/dev/null | jq -r --arg name "$pvc_name" --arg ns "$ns" '.items[] | select(.status.phase == "Released" and .spec.claimRef.name == $name and .spec.claimRef.namespace == $ns) | .metadata.name' | while read -r pv; do
				kubectl patch pv "$pv" --type=json -p='[{"op": "remove", "path": "/spec/claimRef/uid"}]' 2>/dev/null || true
			done
		done <<< "$_pvcs"
	fi
}

_k3s_diff() { printf '%s\n' "$PROCESSED_YAML" | kubectl diff -f - || true; }
_k3s_yaml() { printf '%s\n' "$PROCESSED_YAML"; }

trap 'rm -rf "${_cleanup_dirs[@]:-}"' EXIT
declare -a _cleanup_dirs=()

case "$MODE" in
	apply)
		_run_hook prep.sh
		_check_initial_prereqs
		_build_yaml false
		_k3s_apply
		_run_hook post.sh ;;
	initial)
		_run_hook prep.sh
		_build_yaml true
		_k3s_apply
		_run_hook post.sh
		_initial_reminder ;;
	delete)
		_build_yaml false
		_k3s_delete ;;
	diff)
		_build_yaml false
		_k3s_diff ;;
	yaml)
		_build_yaml false
		_k3s_yaml ;;
	*)
		echo "Error: Unknown mode '$MODE'. Valid modes: apply, initial, delete, diff, yaml" >&2
		exit 1 ;;
esac