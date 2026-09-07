#!/bin/bash
# DESC: Render templates from VARS + helm upgrade/install for the srv0 umbrella chart
# Usage: helm.sh <release> <base|apps> [helm args...]
set -euo pipefail
source "$INFRA_ROOT/lib/common.sh"

RELEASE="${1:?Usage: helm.sh <release> <base|apps> [helm args...]}"
SCOPE="${2:?}"
shift 2

case "$SCOPE" in
    base) OTHER_GROUP=apps ;;
    apps) OTHER_GROUP=base ;;
    *) echo "Error: scope must be base or apps" >&2; exit 1 ;;
esac

CHART_DIR="$INFRA_ROOT/targets/${TARGET:?TARGET not set}/k3s"
STAGED="$K3S_STATE_DIR/chart"

# k3s's kubectl auto-resolves the local admin config; plain helm does not.
[ -n "${KUBECONFIG:-}" ] || [ -r /etc/rancher/k3s/k3s.yaml ] && export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# Stage the chart and envsubst every template from the VARS environment
# (equivalent to the old kustomize pipeline's envsubst pass; helm then only
# handles release management, history, rollback, and hooks).
rm -rf "$STAGED"
mkdir -p "$STAGED"
cp -r "$CHART_DIR"/. "$STAGED"/
while IFS= read -r -d '' f; do
    envsubst "$ENVSUBST_VARS" < "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done < <(find "$STAGED/templates" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)

exec helm upgrade --install "$RELEASE" "$STAGED" \
    -n "$SCOPE" --create-namespace \
    -f "$STAGED/values.yaml" \
    --set "$OTHER_GROUP.enabled=false" \
    "$@"
