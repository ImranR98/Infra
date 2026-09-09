#!/bin/bash
# DESC: Validate one target's configuration: VARS completeness + placeholder
# values (srv0: YAML for helm; vps0: dotenv for compose) and the k3s umbrella
# chart render (helm lint + both scopes). Variable NAMES only are printed —
# values never reach stdout/stderr. Runs from any machine.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"

usage() {
    echo "Usage: $(basename "$0") <target>"
    echo
    echo "Checks (target-dependent):"
    echo "  - secrets/VARS.<target>.yaml exists, has every key from VARS.template.yaml,"
    echo "    and no placeholder values (srv0 — the file helm consumes)"
    echo "  - secrets/VARS.<target>.env exists, has every key from VARS.template.env,"
    echo "    and no placeholder values (vps0 — the file compose consumes)"
    echo "  - helm lint + helm template of both scopes of targets/<target>/k3s,"
    echo "    rejecting '<no value>' renders"
    exit 1
}

_err() { echo "validate: $*" >&2; }

# check_yaml_vars <target_dir> — VARS completeness + placeholders, key names only.
check_yaml_vars() {
    local target_dir="$1"
    local template="$target_dir/VARS.template.yaml"
    local secrets_file="$INFRA_ROOT/secrets/VARS.$TARGET.yaml"
    local ok=1

    if [ ! -f "$secrets_file" ]; then
        _err "ERROR: $secrets_file not found — create it from $template"
        return 1
    fi

    local missing
    missing=$(comm -23 \
        <(yq '. | keys | .[]' "$template" | sort) \
        <(yq '. | keys | .[]' "$secrets_file" | sort))
    if [ -n "$missing" ]; then
        _err "ERROR: secrets/VARS.$TARGET.yaml is missing required variables:"
        awk '{print "  " $0}' <<<"$missing" >&2
        ok=0
    fi

    local placeholders
    placeholders=$(yq \
        'to_entries[] | select((.value | type) == "!!str") |
         select((.value | trim) == "change_me" or (.value | trim) == "changeme" or
                (.value | trim) == "abc" or (.value | trim) == "REPLACE_ME" or
                (.value | trim | test("^<.*>$"))) | .key' \
        "$secrets_file")
    if [ -n "$placeholders" ]; then
        _err "ERROR: secrets/VARS.$TARGET.yaml: these variables have placeholder values:"
        awk '{print "  " $0}' <<<"$placeholders" >&2
        ok=0
    fi
    [ "$ok" = 1 ]
}

# check_env_vars <target_dir> — dotenv completeness + placeholders, key names only.
check_env_vars() {
    local target_dir="$1"
    local template="$target_dir/VARS.template.env"
    local env_file="$INFRA_ROOT/secrets/VARS.$TARGET.env"
    local ok=1

    if [ ! -f "$env_file" ]; then
        _err "ERROR: $env_file not found — create it from $template"
        return 1
    fi

    local missing
    missing=$(comm -23 \
        <(grep -oE '^[A-Z_][A-Z_0-9]*=' "$template" | tr -d '=' | sort) \
        <(grep -oE '^[A-Z_][A-Z_0-9]*=' "$env_file" | tr -d '=' | sort))
    if [ -n "$missing" ]; then
        _err "ERROR: secrets/VARS.$TARGET.env is missing required variables:"
        awk '{print "  " $0}' <<<"$missing" >&2
        ok=0
    fi

    local placeholders
    placeholders=$(awk -F= '
        /^[A-Z_][A-Z_0-9]*=/ {
            v = substr($0, index($0, "=") + 1)
            gsub(/^[ \t"'"'"']+|[ \t"'"'"']+$/, "", v)
            if (v == "change_me" || v == "changeme" || v == "abc" ||
                v == "REPLACE_ME" || v ~ /^<.*>$/) print $1
        }' "$env_file")
    if [ -n "$placeholders" ]; then
        _err "ERROR: secrets/VARS.$TARGET.env: these variables have placeholder values:"
        awk '{print "  " $0}' <<<"$placeholders" >&2
        ok=0
    fi
    [ "$ok" = 1 ]
}

# check_helm <target_dir> — lint + both-scope template render of the k3s chart.
check_helm() {
    local target_dir="$1"
    local chart="$target_dir/k3s"
    local vars_args=(-f "$chart/values.yaml")
    local secrets_file="$INFRA_ROOT/secrets/VARS.$TARGET.yaml"
    local ok=1

    [ -f "$secrets_file" ] && vars_args+=(-f "$secrets_file")

    if ! helm lint "$chart" "${vars_args[@]}" >/dev/null 2>&1; then
        _err "ERROR: helm lint failed"
        ok=0
    fi

    local scope other out
    for scope in base apps; do
        [ "$scope" = base ] && other=apps || other=base
        out=$(helm template "$TARGET-$scope" "$chart" -n "$scope" \
            "${vars_args[@]}" --set "$other.enabled=false" 2>&1) || {
            _err "ERROR: helm template ($scope) failed:"
            echo "$out" >&2
            ok=0
            continue
        }
        if grep -q '<no value>' <<<"$out"; then
            _err "ERROR: helm template ($scope) rendered missing values (<no value>)"
            ok=0
        fi
    done
    [ "$ok" = 1 ]
}

[ $# -ge 1 ] || usage
require_target "$1"
target_dir="$INFRA_ROOT/targets/$TARGET"
ok=1

if [ -f "$target_dir/VARS.template.yaml" ] && [ -d "$target_dir/k3s" ]; then
    check_yaml_vars "$target_dir" || ok=0
    check_helm "$target_dir" || ok=0
elif [ -f "$target_dir/VARS.template.env" ]; then
    check_env_vars "$target_dir" || ok=0
else
    echo "validate: target '$TARGET' has no VARS template and no k3s chart — nothing to check"
fi

if [ "$ok" = 1 ]; then
    echo "validate: OK ($TARGET)"
    exit 0
fi
exit 1
