#!/bin/bash
# DESC: Deploy, delete, diff, or render a single K3s component
set -euo pipefail

COMPONENT="${1:-}"
MODE="${2:-apply}"

if [ -z "$COMPONENT" ]; then
    echo "Error: No component specified." >&2
    echo "Usage: $0 <component> [mode]" >&2
    echo "Available components:" >&2
    for d in "$INFRA_ROOT/targets/$TARGET/k3s"/*/; do
        [ -d "$d" ] || continue
        printf '  %s\n' "$(basename "$d")"
    done
    exit 1
fi

COMPONENT_DIR="$INFRA_ROOT/targets/$TARGET/k3s/$COMPONENT"

if [ ! -d "$COMPONENT_DIR" ]; then
    echo "Error: Unknown component '$COMPONENT'" >&2
    exit 1
fi

source "$INFRA_ROOT/lib/common.sh"
source_env
ensure_envsubst_vars

_build_yaml() {
    # Stage files into a temp dir so we can envsubst BEFORE kustomize.
    # This lets bare $VAR references (including multi-line shell variables)
    # sit directly in YAML source files without needing workaround markers.
    TMP_DIR=$(mktemp -d)
    _cleanup_dirs+=("$TMP_DIR")
    # Copy every file (YAML resources plus plugin files for the traefik
    # component's configMapGenerator); kustomize ignores unreferenced files.
    # dotglob is enabled in a subshell so hidden files like .traefik.yml
    # are staged too.
    (
        shopt -s dotglob
        for f in "$COMPONENT_DIR"/*; do
            [ -f "$f" ] || continue
            cp "$f" "$TMP_DIR/"
        done
    )

    # envsubst each file in place so variable references expand directly
    # into the YAML text before kustomize parses it.
    for f in "$TMP_DIR"/*.yaml; do
        [ -f "$f" ] || continue
        envsubst "$ENVSUBST_VARS" < "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    done

    RAW_YAML=$(kubectl kustomize "$TMP_DIR") || { echo "Error: kustomize build failed for $COMPONENT" >&2; exit 1; }

    # kustomize strips YAML quotes; envsubst makes numeric vars bare ints.
    # Kubernetes rejects unquoted ints in env[].value.  Sed re-quotes them.
    PROCESSED_YAML=$(printf '%s\n' "$RAW_YAML" | sed -E 's/^(\s+value: )([+-]?[0-9]+)$/\1"\2"/')
}

_run_hook() {
    local hook="$1"
    if [ -f "$COMPONENT_DIR/$hook" ]; then bash "$COMPONENT_DIR/$hook"; fi
}

_k3s_apply() {
    printf '%s\n' "$PROCESSED_YAML" | kubectl apply -f -
}

_delete_resource_with_timeout() {
    local kind="$1" ns="$2" name="$3" timeout="${4:-30s}"
    kubectl delete "$kind" "$name" -n "$ns" --wait=false 2>/dev/null || true
    kubectl get "$kind" "$name" -n "$ns" >/dev/null 2>&1 || return 0
    kubectl wait --for=delete "$kind" "$name" -n "$ns" --timeout="$timeout" >/dev/null 2>&1 \
        || { kubectl get "$kind" "$name" -n "$ns" >/dev/null 2>&1 \
             && { echo "Error: $kind $ns/$name did not finish deleting within $timeout" >&2; exit 1; }; }
    return 0
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
            pvc_release_pv "$pvc_name" "$ns"
        done <<< "$_pvcs"
    fi
}

_k3s_diff() { printf '%s\n' "$PROCESSED_YAML" | kubectl diff -f - || true; }
_k3s_yaml() { printf '%s\n' "$PROCESSED_YAML"; }

declare -a _cleanup_dirs=()
trap 'rm -rf "${_cleanup_dirs[@]:-}"' EXIT

case "$MODE" in
    apply)
        _run_hook prep.sh
        if ! kubectl get service authelia -n base >/dev/null 2>&1; then
            export AUTHELIA_HEADER_GATE_ENABLED="true"
        fi
        _build_yaml
        _k3s_apply
        _run_hook post.sh ;;
    delete)
        _build_yaml
        _k3s_delete ;;
    diff)
        _build_yaml
        _k3s_diff ;;
    yaml)
        _build_yaml
        _k3s_yaml ;;
    *)
        echo "Error: Unknown mode '$MODE'. Valid modes: apply, delete, diff, yaml" >&2
        exit 1 ;;
esac