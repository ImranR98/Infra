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

source "$ROOT_DIR/scripts/common.sh"
source_env
ENVSUBST_VARS="$(get_envsubst_vars)"

if [[ ("$MODE" == "apply" || "$MODE" == "initial") && -f "$COMPONENT_DIR/prep.sh" ]]; then
	bash "$COMPONENT_DIR/prep.sh"
fi

if [ "$MODE" = "initial" ] && [ -f "$COMPONENT_DIR/kustomization.yaml" ]; then
	TMP_DIR=$(mktemp -d)
	trap "rm -rf '$TMP_DIR'" EXIT
	for f in "$COMPONENT_DIR"/*.yaml; do
		sed '/# initially-removed$/d' "$f" > "$TMP_DIR/$(basename "$f")"
	done
	RAW_YAML=$(kubectl kustomize "$TMP_DIR")
else
	if [ -f "$COMPONENT_DIR/kustomization.yaml" ]; then
		RAW_YAML=$(kubectl kustomize "$COMPONENT_DIR")
	else
		RAW_YAML=$(awk 'FNR==1 && NR!=1 {print "---"} {print}' "$COMPONENT_DIR"/*.yaml)
	fi
fi

PROCESSED_YAML=$(printf '%s\n' "$RAW_YAML" | envsubst "$ENVSUBST_VARS")

if [ "$MODE" = "initial" ] && [ ! -f "$COMPONENT_DIR/kustomization.yaml" ]; then
	PROCESSED_YAML=$(printf '%s\n' "$PROCESSED_YAML" | sed '/# initially-removed$/d')
fi

if [ "$MODE" = "delete" ]; then
	[ -f "$COMPONENT_DIR/delete.sh" ] && bash "$COMPONENT_DIR/delete.sh"

	printf '%s\n' "$PROCESSED_YAML" | kubectl delete --wait=false --ignore-not-found -f - 2>&1 || true

	# Wait for PVCs to be fully deleted before returning
	printf '%s\n' "$PROCESSED_YAML" | yq -r 'select(.kind == "PersistentVolumeClaim") | .metadata.namespace + "/" + .metadata.name' 2>/dev/null | sed '/^---$/d' | while IFS="/" read -r ns pvc_name; do
		[ -z "$pvc_name" ] && continue
		echo "Waiting for PVC $ns/$pvc_name to be deleted..."
		_deleted=false
		for _ in $(seq 1 30); do
			if ! kubectl get pvc -n "$ns" "$pvc_name" >/dev/null 2>&1; then
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
		if echo "$output" | grep -qiE "connection refused|no route to host|no such host|i/o timeout"; then
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
