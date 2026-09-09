#!/bin/bash
# DESC: Validate one target's configuration. For targets with a
# config_template/ folder: every template file must have its filled counterpart
# in config/<target>/ (same relative path) with no leftover placeholders; the
# helm values (values.yaml) and compose env (compose.env) additionally get
# key-completeness checks against the template. Targets with a k3s chart get
# helm lint + both-scope template renders ('<no value>' rejected); compose
# mounts under ../../../config/ must exist. Variable NAMES and paths only are
# printed — values never reach stdout/stderr. Runs from any machine.
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
    echo "  - every file in targets/<target>/config_template/ exists in config/<target>/"
    echo "    (same relative path) and contains no template placeholders"
    echo "  - values.yaml: key completeness vs the template + placeholder values"
    echo "  - compose.env: key completeness vs the template + placeholder values"
    echo "  - helm lint + helm template of both scopes of targets/<target>/k3s"
    echo "  - compose mounts under ../../../config/ point at existing files"
    exit 1
}

_err() { echo "validate: $*" >&2; }

# check_yaml_vars <template> <config> — VARS completeness + placeholders, key names only.
check_yaml_vars() {
    local template="$1" config_file="$2"
    local ok=1

    local missing
    missing=$(comm -23 \
        <(yq '. | keys | .[]' "$template" | sort) \
        <(yq '. | keys | .[]' "$config_file" | sort))
    if [ -n "$missing" ]; then
        _err "ERROR: $config_file is missing required variables:"
        awk '{print "  " $0}' <<<"$missing" >&2
        ok=0
    fi

    local placeholders
    placeholders=$(yq \
        'to_entries[] | select((.value | type) == "!!str") |
         select((.value | trim) == "change_me" or (.value | trim) == "changeme" or
                (.value | trim) == "abc" or (.value | trim) == "REPLACE_ME" or
                (.value | trim | test("^<.*>$"))) | .key' \
        "$config_file")
    if [ -n "$placeholders" ]; then
        _err "ERROR: $config_file: these variables have placeholder values:"
        awk '{print "  " $0}' <<<"$placeholders" >&2
        ok=0
    fi
    [ "$ok" = 1 ]
}

# check_env_vars <template> <config> — dotenv completeness + placeholders, key names only.
check_env_vars() {
    local template="$1" config_file="$2"
    local ok=1

    local missing
    missing=$(comm -23 \
        <(grep -oE '^[A-Z_][A-Z_0-9]*=' "$template" | tr -d '=' | sort) \
        <(grep -oE '^[A-Z_][A-Z_0-9]*=' "$config_file" | tr -d '=' | sort))
    if [ -n "$missing" ]; then
        _err "ERROR: $config_file is missing required variables:"
        awk '{print "  " $0}' <<<"$missing" >&2
        ok=0
    fi

    local placeholders
    placeholders=$(awk -F= '
        /^[A-Z_][A-Z_0-9]*=/ {
            v = substr($0, index($0, "=") + 1)
            gsub(/^[ \t"'"'"']+|[ \t"'"'"']+$/, "", v)
            sub(/[ \t]+#.*$/, "", v)
            if (v == "change_me" || v == "changeme" || v == "abc" ||
                v == "REPLACE_ME" || v ~ /^<.*>$/) print $1
        }' "$config_file")
    if [ -n "$placeholders" ]; then
        _err "ERROR: $config_file: these variables have placeholder values:"
        awk '{print "  " $0}' <<<"$placeholders" >&2
        ok=0
    fi
    [ "$ok" = 1 ]
}

# check_config_files <template_dir> <config_dir> — every template file needs a
# filled counterpart; placeholder scan for non-values/non-env files.
check_config_files() {
    local template_dir="$1" config_dir="$2"
    local ok=1

    if [ ! -d "$config_dir" ]; then
        _err "ERROR: $config_dir not found — create it from the template:"
        _err "  cp -r $template_dir $config_dir   (then fill in the real values)"
        return 1
    fi

    while IFS= read -r tfile; do
        rel="${tfile#"$template_dir"/}"
        cfile="$config_dir/$rel"
        if [ ! -f "$cfile" ]; then
            _err "ERROR: missing config file: $cfile (template: $template_dir/$rel)"
            ok=0
            continue
        fi
        case "$rel" in
            values.yaml) check_yaml_vars "$tfile" "$cfile" || ok=0 ;;
            compose.env) check_env_vars "$tfile" "$cfile" || ok=0 ;;
            *)
                if grep -qE 'change_me|changeme|REPLACE_ME|<[A-Za-z]' "$cfile"; then
                    _err "ERROR: $cfile still contains template placeholders"
                    ok=0
                fi
                ;;
        esac
    done < <(find "$template_dir" -type f | sort)
    [ "$ok" = 1 ]
}

# check_compose_mounts <target_dir> — config/ mounts referenced by the compose
# files must point at existing files.
check_compose_mounts() {
    local target_dir="$1"
    local ok=1

    local f
    for f in "$target_dir/compose/compose.yaml" "$target_dir/compose/compose.private.yaml"; do
        [ -f "$f" ] || continue
        while read -r src; do
            [ -f "$target_dir/compose/$src" ] || {
                _err "ERROR: compose mount points at a missing file: $src"
                ok=0
            }
        done < <(sed -n 's/^[[:space:]]*-[[:space:]]*\(\.\.\/\.\.\/\.\.\/config\/[A-Za-z0-9_.\/-]*\).*/\1/p' "$f")
    done
    [ "$ok" = 1 ]
}

# check_helm <target_dir> — lint + both-scope template render of the k3s chart.
check_helm() {
    local target_dir="$1"
    local chart="$target_dir/k3s"
    local vars_args=(-f "$chart/values.yaml")
    local config_file="$INFRA_ROOT/config/$TARGET/values.yaml"
    local ok=1

    [ -f "$config_file" ] && vars_args+=(-f "$config_file")

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
template_dir="$target_dir/config_template"
ok=1

if [ -d "$template_dir" ]; then
    check_config_files "$template_dir" "$INFRA_ROOT/config/$TARGET" || ok=0
else
    echo "validate: target '$TARGET' has no config_template (no secret variables) — nothing to check"
fi

[ -d "$target_dir/k3s" ] && { check_helm "$target_dir" || ok=0; }

[ -d "$target_dir/compose" ] && { check_compose_mounts "$target_dir" || ok=0; }

if [ "$ok" = 1 ]; then
    echo "validate: OK ($TARGET)"
    exit 0
fi
exit 1
