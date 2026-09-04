#!/bin/bash
# lib/validate.sh — variable reference checking and YAML/kustomize validation

_build_known_vars() {
    local target="$1"; shift
    local known="$*" hashed_vars
    while IFS= read -r v; do
        if [ -z "$v" ]; then continue; fi
        known+="
$v"
    done < <(get_template_export_names "$target")
    # Derive _HASHED counterparts for every _HASHABLE variable
    hashed_vars=$(echo "$known" | grep '_HASHABLE$' | sed 's/_HASHABLE$/_HASHED/')
    for hv in $hashed_vars; do
        known+="
$hv"
    done
    echo "$known"
}

_has_structural_vars() {
    local path="$1"
    if [ -f "$path" ]; then
        grep -qP '^\s+\$[A-Z_][A-Z_0-9]*\s*$' "$path" && return 0
    elif [ -d "$path" ]; then
        for f in "$path"/*.yaml "$path"/*.yml; do
            [ -f "$f" ] || continue
            grep -qP '^\s+\$[A-Z_][A-Z_0-9]*\s*$' "$f" && return 0
        done
    fi
    return 1
}

_check_var_refs() {
    local known_vars="$1" file="$2"
    [ -f "$file" ] || return 0
    local refs; refs=$(grep -oP '\$[A-Z_][A-Z_0-9]*|\$\{[A-Z_][A-Z_0-9]*\}' "$file" 2>/dev/null | sed 's/^\${//; s/^\$//; s/}$//' | sort -u)
    if [ -z "$refs" ]; then return 0; fi
    echo "$refs" | grep -vxFf <(echo "$known_vars") | while read -r v; do
        if [ -z "$v" ]; then continue; fi
        echo "Error: $(basename "$file") references '\$$v' but it's not defined in VARS template"
    done
}

validate() {
    local target="${1:-$TARGET}"
    local k3s_ok=true compose_ok=true

    if [ -d "$INFRA_ROOT/targets/$target/k3s" ]; then
        _validate_k3s "$target" || k3s_ok=false
    fi
    if [ -f "$INFRA_ROOT/targets/$target/compose/compose.yaml" ]; then
        _validate_compose "$target" || compose_ok=false
    fi

    echo ""
    echo "K3s:     $( $k3s_ok && echo "OK" || echo "issues found" )"
    echo "Compose: $( $compose_ok && echo "OK" || echo "issues found" )"
}

_count_ref_errors() {
    local known_vars="$1" file="$2"
    local ref_errors; ref_errors=$(_check_var_refs "$known_vars" "$file")
    if [ -n "$ref_errors" ]; then
        echo "$ref_errors" >&2
        echo "$(echo "$ref_errors" | wc -l)"
        return 0
    fi
    echo 0
}

_validate_k3s() {
    local target="$1" comp_dir="$INFRA_ROOT/targets/$target/k3s" errors=0

    local known_vars; known_vars=$(_build_known_vars "$target" "MY_UID
TARGET
INFRA_ROOT
COMPOSE_STATE_DIR
COMPOSE_STATE_BACKUP_DIR
K3S_STATE_DIR
PVC_BACKUP_DIR
NS
PV
PVC
VOLUMES")

    for comp_dir in "$comp_dir"/*/; do
        local comp; comp=$(basename "$comp_dir")
        local kfile="$comp_dir/kustomization.yaml"

        [ -f "$kfile" ] || { echo "Error: $comp missing kustomization.yaml"; errors=$((errors + 1)); continue; }

        if command -v kubectl >/dev/null 2>&1; then
            local k_err; k_err=$(kubectl kustomize "$comp_dir" 2>&1 1>/dev/null) || {
                if echo "$k_err" | grep -q "could not find expected ':'" && _has_structural_vars "$comp_dir"; then
                    echo "Warning: $comp kustomize skipped (structural \$VARIABLE placeholder)"
                else
                    echo "Error: $comp kustomize build failed"; errors=$((errors + 1))
                fi
            }
        fi

        local yaml_files=()
        for yf in "$comp_dir"/*.yaml "$comp_dir"/*.yml; do if [ -f "$yf" ]; then yaml_files+=("$yf"); fi; done
        for yf in "${yaml_files[@]}"; do
            errors=$((errors + $(_count_ref_errors "$known_vars" "$yf")))
        done
    done

    echo ""
    echo "K3s validation: $errors errors"
    return $(( errors > 0 ? 1 : 0 ))
}

_validate_compose() {
    local target="$1" errors=0

    local private_file="$INFRA_ROOT/targets/$target/compose/compose.private.yaml"
    for f in "$INFRA_ROOT/targets/$target/compose/compose.yaml" $([ -f "$private_file" ] && echo "$private_file"); do
        [ -f "$f" ] || continue
        if [[ "$f" =~ \.(yaml|yml)$ ]]; then
            if ! yq eval '.' "$f" >/dev/null 2>&1; then
                if _has_structural_vars "$f"; then
                    echo "Warning: $(basename "$f") YAML syntax skipped (structural \$VARIABLE placeholder)"
                else
                    echo "Error: $(basename "$f") has invalid YAML syntax"
                    errors=$((errors + 1))
                fi
            fi
        fi
    done
    while IFS= read -r -d '' f; do
        [[ "$f" =~ \.(yaml|yml)$ ]] || continue
        if ! yq eval '.' "$f" >/dev/null 2>&1; then
            if _has_structural_vars "$f"; then
                echo "Warning: $(basename "$f") YAML syntax skipped (structural \$VARIABLE placeholder)"
            else
                echo "Error: $(basename "$f") has invalid YAML syntax"
                errors=$((errors + 1))
            fi
        fi
    done < <(find "$INFRA_ROOT/targets/$target/compose/templates" -type f -print0 2>/dev/null)

    local known_vars; known_vars=$(_build_known_vars "$target" "MY_UID
TARGET
DOCKER_GID
COMPOSE_STATE_DIR
USER")

    local compose_files=("$INFRA_ROOT/targets/$target/compose/compose.yaml")
    [ -f "$private_file" ] && compose_files+=("$private_file")
    for f in "$INFRA_ROOT/targets/$target/compose/templates"/*; do if [ -f "$f" ]; then compose_files+=("$f"); fi; done
    for f in "${compose_files[@]}"; do
        errors=$((errors + $(_count_ref_errors "$known_vars" "$f")))
    done

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        if [ -f "$COMPOSE_STATE_DIR/compose.yaml" ]; then
            docker compose -f "$COMPOSE_STATE_DIR/compose.yaml" config --dry-run >/dev/null || { echo "Error: docker compose config validation failed"; errors=$((errors + 1)); }
        fi
    fi

    echo ""
    echo "Compose validation: $errors errors"
    return $(( errors > 0 ? 1 : 0 ))
}
