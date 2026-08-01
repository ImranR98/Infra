#!/bin/bash
# lib/compose.sh — Docker Compose template rendering and domain listing

render_compose_yaml() {
    ensure_envsubst_vars
    mkdir -p "$COMPOSE_STATE_DIR"
    envsubst "$ENVSUBST_VARS" < "$INFRA_ROOT/targets/$TARGET/compose/compose.yaml" > "$COMPOSE_STATE_DIR/compose.yaml"
}

configure_compose_templates() {
    local target="$1"
    ensure_envsubst_vars
    if [ -n "${PROXY_HOST:-}" ]; then
        PROXY_IP="$(getent hosts "$PROXY_HOST" 2>/dev/null | awk '{print $1; exit}')"
        if [ -z "$PROXY_IP" ]; then
            echo "Warning: could not resolve PROXY_HOST='$PROXY_HOST' to an IP address" >&2
        else
            export PROXY_IP
        fi
    fi
    local template_dir="$INFRA_ROOT/targets/$target/compose/templates"
    [ -d "$template_dir" ] || return 0

    declare -A _compose_hooks_run

    while IFS= read -r -d '' src; do
        local rel="${src#$template_dir/}"
        local dst="$COMPOSE_STATE_DIR/$rel"
        dst="${dst%.secret}"
        dst="${dst%.plain}"
        mkdir -p "$(dirname "$dst")"

        local component="${rel%%/*}"
        if [ "${_compose_hooks_run[$component]:-}" != "1" ]; then
            _compose_hooks_run[$component]=1
            local chook="$template_dir/$component/prep.sh"
            [ -f "$chook" ] && bash "$chook"
        fi

        case "$rel" in
            *.plain) cp "$src" "$dst" ;;
            *.secret)
                if [ ! -f "$dst" ] && grep -q '# IGNORE INITIALLY$' "$src" 2>/dev/null; then
                    sed '/# IGNORE INITIALLY$/ s/^/# /' "$src" | envsubst "$ENVSUBST_VARS" > "$dst"
                else
                    envsubst "$ENVSUBST_VARS" < "$src" > "$dst"
                fi
                chmod 600 "$dst" ;;
            *)
                envsubst "$ENVSUBST_VARS" < "$src" > "$dst" ;;
        esac
    done < <(find "$template_dir" -type f -print0)
}

list_domains() {
    local target="${1:-$TARGET}"
    local sd="${SERVICES_DOMAIN:-}"
    if [ -z "$sd" ]; then sd='$SERVICES_DOMAIN'; fi

    _extract_hosts() {
        grep -rohP 'Host\(`[^`]+`\)' "$@" 2>/dev/null | \
            sed 's/.*`\([^`]*\)`.*/\1/' | \
            grep -v '\.localhost'
    }

    if [ -d "$INFRA_ROOT/targets/$target/k3s" ]; then
        _extract_hosts --include='*.yaml' "$INFRA_ROOT/targets/$target/k3s" | \
            sed "s/\\\$SERVICES_DOMAIN/${sd}/g" | \
            sort -u
    fi

    if [ -f "$INFRA_ROOT/targets/$target/compose/compose.yaml" ]; then
        _extract_hosts "$INFRA_ROOT/targets/$target/compose/compose.yaml" | \
            sed "s/\\\$SERVICES_DOMAIN/${sd}/g" | \
            sort -u
    fi
}
