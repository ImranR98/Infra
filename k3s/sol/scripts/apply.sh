#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
COMPONENT="$1"
MODE="${2:-apply}"

case "$MODE" in
	apply|initial|delete|diff|yaml) ;;
	*)
		echo "Error: Unknown APPLY_MODE '$MODE'. Valid modes: apply, initial, delete, diff, yaml" >&2
		exit 1
		;;
esac

COMPONENT_DIR="$ROOT_DIR/components/$COMPONENT"

if [ ! -d "$COMPONENT_DIR" ]; then
	echo "Error: Unknown component '$COMPONENT'" >&2
	exit 1
fi

export VARS_ROOT="$(cd "$ROOT_DIR/../.." >/dev/null 2>&1 && pwd)"
export TARGET="$(basename "$ROOT_DIR")"
source "$VARS_ROOT/lib/vars.sh"
source_env
ENVSUBST_VARS="$(get_envsubst_vars)"

if [[ ("$MODE" == "apply" || "$MODE" == "initial") && -f "$COMPONENT_DIR/prep.sh" ]]; then
	bash "$COMPONENT_DIR/prep.sh"
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

	printf '%s\n' "$PROCESSED_YAML" | kubectl delete --wait=false --ignore-not-found -f - 2>&1 || true

	# Wait for PVCs to be fully deleted before returning
	printf '%s\n' "$PROCESSED_YAML" | yq -r 'select(.kind == "PersistentVolumeClaim") | .metadata.namespace + "/" + .metadata.name' 2>/dev/null | sed '/^---$/d' | while IFS="/" read -r ns pvc_name; do
		[ -z "$pvc_name" ] && continue
		echo "Waiting for PVC $ns/$pvc_name to be deleted..."
		_deleted=false
		for _ in $(seq 1 30); do
			if kubectl get pvc -n "$ns" "$pvc_name" >/dev/null 2>&1; then
				_exists=true
			else
				_exists=false
			fi
			if [ "$_exists" = false ]; then
				_deleted=true
				break
			fi
			sleep 2
		done
		if [ "$_deleted" = false ]; then
			echo "Warning: PVC $ns/$pvc_name was not deleted within 60s." >&2
		fi
		# Clear claimRef.uid on Released PVs so new PVCs with the same name can bind
		kubectl get pv -o json 2>/dev/null | jq -r ".items[] | select(.status.phase == \"Released\" and .spec.claimRef.name == \"$pvc_name\" and .spec.claimRef.namespace == \"$ns\") | .metadata.name" | while read -r pv; do
			kubectl patch pv "$pv" --type=json -p='[{"op": "remove", "path": "/spec/claimRef/uid"}]' 2>/dev/null || true
		done
	done
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
