#!/bin/bash
# lib/validate.sh — YAML/helm-chart/docker-compose validation.
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

    if [ "$target" = "srv0" ] && [ -d "$INFRA_ROOT/charts/srv0" ]; then
        _validate_helm || k3s_ok=false
    fi
    if [ -f "$INFRA_ROOT/targets/$target/compose/compose.yaml" ]; then
        _validate_compose "$target" || compose_ok=false
    fi

    echo ""
    echo "K3s:     $( $k3s_ok && echo "OK" || echo "issues found" )"
    echo "Compose: $( $compose_ok && echo "OK" || echo "issues found" )"
}

_validate_helm() {
    local errors=0 chart="$INFRA_ROOT/charts/srv0"
    if command -v helm >/dev/null 2>&1; then
        local staged="$K3S_STATE_DIR/chart-validate"
        rm -rf "$staged"
        mkdir -p "$(dirname "$staged")"
        cp -r "$chart" "$staged"
        # envsubst the templates exactly like commands/k3s/helm.sh does
        while IFS= read -r -d '' f; do
            envsubst "$ENVSUBST_VARS" < "$f" > "$f.tmp" && mv "$f.tmp" "$f"
        done < <(find "$staged/templates" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)
        helm lint "$staged" >/dev/null 2>&1 || { echo "Error: helm lint failed"; errors=$((errors + 1)); }
        for scope in base apps; do
            if [ "$scope" = "base" ]; then other=apps; else other=base; fi
            if ! helm template "srv0-$scope" "$staged" -n "$scope" --set "$other.enabled=false" >/dev/null 2>&1; then
                echo "Error: helm template (scope $scope) failed"; errors=$((errors + 1))
            fi
        done
        rm -rf "$staged"
    else
        echo "Warning: helm not installed — skipping chart validation"
    fi
    echo ""
    echo "K3s (helm chart) validation: $errors errors"
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
