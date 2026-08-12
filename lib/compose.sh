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
                envsubst "$ENVSUBST_VARS" < "$src" > "$dst"
                chmod 600 "$dst"
                if [ "$(id -u)" -eq 0 ]; then
                    chown "$MY_UID:$MY_UID" "$dst" 2>/dev/null || :
                fi ;;
            *)
                envsubst "$ENVSUBST_VARS" < "$src" > "$dst" ;;
        esac
    done < <(find "$template_dir" -type f -print0)
}

list_domains() {
    local target="${1:-$TARGET}"

    # Substitute every domain variable from the environment, falling back to
    # the literal $VAR placeholder when unset (so other targets still show
    # their raw references without a VARS file loaded).
    local sed_args=() v val
    for v in SERVICES_DOMAIN BASE_SERVICES_DOMAIN CLOUD_SERVICES_DOMAIN; do
        val="${!v:-}"
        if [ -z "$val" ]; then val="\$$v"; fi
        sed_args+=(-e "s/\\\$$v/${val}/g")
    done

    _extract_hosts() {
        grep -rohP 'Host\(`[^`]+`\)' "$@" 2>/dev/null | \
            sed 's/.*`\([^`]*\)`.*/\1/' | \
            grep -v '\.localhost'
    }

    if [ -d "$INFRA_ROOT/targets/$target/k3s" ]; then
        _extract_hosts --include='*.yaml' "$INFRA_ROOT/targets/$target/k3s" | \
            sed "${sed_args[@]}" | \
            sort -u
    fi

    if [ -f "$INFRA_ROOT/targets/$target/compose/compose.yaml" ]; then
        _extract_hosts "$INFRA_ROOT/targets/$target/compose/compose.yaml" | \
            sed "${sed_args[@]}" | \
            sort -u
    fi
}
