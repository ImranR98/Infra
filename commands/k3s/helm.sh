#!/bin/bash
# DESC: helm upgrade/install for the srv0 umbrella chart
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

CHART_DIR="$INFRA_ROOT/targets/srv0/k3s"
SECRET_VALUES="$INFRA_ROOT/secrets/values.srv0.yaml"

# k3s's kubectl auto-resolves the local admin config; plain helm does not.
[ -n "${KUBECONFIG:-}" ] || [ -r /etc/rancher/k3s/k3s.yaml ] && export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

[ -f "$SECRET_VALUES" ] || {
    echo "Error: $SECRET_VALUES not found. Create it from targets/srv0/VARS.template.env" >&2
    exit 1
}

# Reject placeholder values that would silently deploy a broken config
if grep -qE 'change_me|changeme|REPLACE_ME|^[^#]*"[^"]*<[^>]*>[^"]*"' "$SECRET_VALUES"; then
    echo "Error: $SECRET_VALUES contains placeholder values" >&2
    exit 1
fi

# Preflight: every .Values.NAME referenced by the templates must exist in the
# merged values (helm silently renders missing keys as empty/absent).
missing=$(python3 - "$CHART_DIR" "$CHART_DIR/values.yaml" "$SECRET_VALUES" <<'PY'
import os, re, sys, yaml
chart, vals_yaml, secret_yaml = sys.argv[1:]
values = {}
for f in (vals_yaml, secret_yaml):
    with open(f) as fh:
        values.update(yaml.safe_load(fh) or {})
refs = set()
for dirpath, _, filenames in os.walk(os.path.join(chart, "templates")):
    for fn in filenames:
        if fn.endswith((".yaml", ".yml")):
            for line in open(os.path.join(dirpath, fn)):
                if '{{ "{{"' in line:  # escaped refs belong to the app charts
                    continue
                refs.update(re.findall(r"\.Values\.([A-Za-z_][A-Za-z0-9_]*)", line))
print(" ".join(sorted(r for r in refs if r not in values)))
PY
)
if [ -n "$missing" ]; then
    echo "Error: values missing for: $missing (check $SECRET_VALUES)" >&2
    exit 1
fi

exec helm upgrade --install "$RELEASE" "$CHART_DIR" \
    -n "$SCOPE" --create-namespace \
    -f "$CHART_DIR/values.yaml" \
    -f "$SECRET_VALUES" \
    --set "$OTHER_GROUP.enabled=false" \
    "$@"
