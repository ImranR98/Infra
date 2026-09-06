#!/bin/bash
# lib/validate.sh — YAML/kustomize/docker-compose validation.
# Note: YAML $VARIABLE references are intentionally NOT cross-checked against
# the template here anymore (they were removed as noise-prone); unknown refs
# surface at render time via envsubst leftovers, and VARS content itself is
# strictly validated by lib/vars_validator.py.

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

_validate_k3s() {
    local target="$1" comp_dir="$INFRA_ROOT/targets/$target/k3s" errors=0

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

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        if [ -f "$COMPOSE_STATE_DIR/compose.yaml" ]; then
            docker compose -f "$COMPOSE_STATE_DIR/compose.yaml" config --dry-run >/dev/null || { echo "Error: docker compose config validation failed"; errors=$((errors + 1)); }
        fi
    fi

    echo ""
    echo "Compose validation: $errors errors"
    return $(( errors > 0 ? 1 : 0 ))
}
