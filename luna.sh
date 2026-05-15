#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

printLine() {
    local linechar="${1:-=}"
    local cols
    cols=$(tput cols 2>/dev/null) || cols=80
    printf '%*s' "$cols" '' | tr ' ' "$linechar"
    echo ""
}

printTitle() {
    printLine
    echo "$1"
    printLine
}



if [ -f "$HERE/VARS.sh" ]; then
    while IFS= read -r var; do
        if ! grep -q "^export $var=" "$HERE/VARS.sh"; then
            echo "VARS.sh is missing required variable: $var" >&2
            exit 1
        fi
    done < <(grep -Eo '^export [^=]+' "$HERE"/template.VARS.sh | sed 's/^export //')
    source "$HERE/VARS.sh"
    export MY_UID="$UID"
elif [ "${1:-}" != "prereqs" ]; then
    echo "No VARS.sh found! Copy template.VARS.sh to VARS.sh and fill in the values." >&2
    exit 1
fi

case "${1:-}" in
    install)
        printTitle "Pre-install Sanity Checks"
        FAILED=false
        for cmd in docker yq envsubst; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                echo "Required command not found: $cmd" >&2
                FAILED=true
            fi
        done
        echo "All checks passed."
        printLine -

        printTitle "Create Required Directories"
        tmpfile="$(mktemp)"
        envsubst < "$HERE"/compose.yaml > "$tmpfile"
        yq '.services[] | .volumes[] | select(type == "string")' "$tmpfile" 2>/dev/null | \
            while IFS=: read -r host_path _; do
                case "$host_path" in
                    "$STATE_DIR"/*)
                        local name="$(basename "$host_path")"
                        if [[ "$name" =~ \.[a-zA-Z0-9]{1,5}$ ]]; then
                            mkdir -p "$(dirname "$host_path")" 2>/dev/null || :
                        else
                            mkdir -p "$host_path" 2>/dev/null || :
                        fi
                        ;;
                esac
            done
        mkdir -p "$STATE_DIR/traefik_logs"
        echo "Done."

        printTitle "Re/generate various state files"
        IGNORE_AUTHELIA_IGNORED_LINES=true
        if [ -f "$STATE_DIR/authelia/config/configuration.yml" ]; then
            read -p 'Should the "ignored" lines in the Authelia config still be ignored? [y]: ' IGNORE_AUTHELIA_IGNORED_LINES_RESPONSE
            if [ "$IGNORE_AUTHELIA_IGNORED_LINES_RESPONSE" = 'n' ] || [ "$IGNORE_AUTHELIA_IGNORED_LINES_RESPONSE" = 'N' ]; then
                IGNORE_AUTHELIA_IGNORED_LINES=false
            fi
        fi
        if [ "$IGNORE_AUTHELIA_IGNORED_LINES" = true ]; then
            sed '/# IGNORE INITIALLY$/ s/^/# /' "$HERE"/templates/authelia.config.yaml | envsubst >"$STATE_DIR"/authelia/config/configuration.yml
            echo "Note that the generated Authelia config does not include lines that end with \"# IGNORE INITIALLY\"."
        else
            envsubst < "$HERE"/templates/authelia.config.yaml >"$STATE_DIR"/authelia/config/configuration.yml
        fi

        echo "$AUTHELIA_USERS_DATABASE" >"$STATE_DIR"/authelia/config/users_database.yml
        if [ ! -f "$STATE_DIR"/traefik/acme.json ]; then
            echo '{}' >"$STATE_DIR"/traefik/acme.json
            echo "Created an empty \"acme.json\"."
        fi
        chmod 600 "$STATE_DIR"/traefik/acme.json
        envsubst < "$HERE"/templates/traefik.dynamic-configuration.yaml > "$STATE_DIR"/traefik/dynamic-configuration.yaml
        cp "$HERE"/templates/plausible.clickhouse-config.xml "$STATE_DIR"/plausible/config/clickhouse-config.xml

        echo "Done."

        printTitle "Generate Docker Compose file"
        cp "$tmpfile" "$STATE_DIR"/compose.yaml
        rm -f "$tmpfile"
        echo "Done."

        printTitle "Install and start the Luna service"
        cat > "$STATE_DIR"/luna.service << EOF
[Unit]
Description=luna start
StartLimitIntervalSec=0

[Service]
User=$MY_UID
Type=idle
ExecStart=/usr/bin/docker compose -p luna -f $STATE_DIR/compose.yaml up
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
        sudo bash -c "mv '$STATE_DIR'/luna.service /etc/systemd/system/luna.service && \
            chcon -t systemd_unit_file_t /etc/systemd/system/luna.service 2>/dev/null || true && \
            systemctl daemon-reload && systemctl enable luna.service && \
            systemctl stop luna.service 2>/dev/null || true && sleep 5 && systemctl start luna.service"
        echo "Done."

        printTitle "Finished"
        echo "Note:
        - Some services may need manual setup in their respective GUIs."
        printLine -
        ;;

    restart)
        envsubst < "$HERE"/compose.yaml > "$STATE_DIR"/compose.yaml

        if [ -n "${2:-}" ]; then
            docker compose -p luna -f "$STATE_DIR"/compose.yaml down "$2" || :
            docker compose -p luna -f "$STATE_DIR"/compose.yaml up -d "$2"
        else
            echo "No service specified. Nothing will be restarted."
        fi
        ;;

    old-images)
        current_time=$(date +%s)
        docker images --no-trunc --format "{{.Repository}}:{{.Tag}}\t{{.CreatedAt}}" | \
            while IFS=$'\t' read -r image created; do
                created_time=$(date -d "$created" +%s 2>/dev/null) || continue
                days=$(( (current_time - created_time) / 86400 ))
                if [ "$days" -gt 60 ]; then
                    printf "%-50s %3d days\n" "$image" "$days"
                fi
            done | sort -k2 -n
        ;;

    update-socket-proxy)
        printTitle "Pull Latest 'wollomatic/socket-proxy:1' and Restart Luna if Needed"

        OLDSPHASH="$(docker images wollomatic/socket-proxy:1 --format '{{.ID}}')"
        docker pull wollomatic/socket-proxy:1
        NEWSPHASH="$(docker images wollomatic/socket-proxy:1 --format '{{.ID}}')"

        if [ "$OLDSPHASH" != "$NEWSPHASH" ]; then
            read -p "New image pulled. Press enter to restart luna..." NOTHING
            sudo systemctl restart luna
        else
            echo "wollomatic/socket-proxy:1 is already the latest (only the :1 tag is tracked)."
        fi
        ;;

    list-domains)
        grep Host "$HERE"/compose.yaml | awk -F '`' '{print $2}' | sort | uniq | envsubst
        ;;

    update-traefik-plugins)
        for cmd in yq jq; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                echo "$cmd is required but not installed." >&2
                exit 1
            fi
        done

        PLUGIN_LINES="$(yq '.services.traefik.command' "$HERE/compose.yaml")"

        while IFS= read -r l; do
            PLUGIN_URL="$(echo "$l" | awk -F= '{print $NF}')"
            if ! echo "$PLUGIN_URL" | grep -q 'github.com/'; then
                echo "UNSUPPORTED PLUGIN: $PLUGIN_URL"
                continue
            fi
            PLUGIN_NAME="$(echo "$l" | awk -F. '{print $3}')"
            PLUGIN_CURRENT_VERSION="$(echo "$PLUGIN_LINES" | grep -o "\.plugins\.$PLUGIN_NAME\.version=[^\"]*" | awk -F= '{print $NF}')"
            PLUGIN_LATEST_VERSION="$(curl -s "https://api.github.com/repos$(echo "$PLUGIN_URL" | sed 's|github\.com/||')/releases/latest" | jq -r '.tag_name')"
            if [ "$PLUGIN_CURRENT_VERSION" != "$PLUGIN_LATEST_VERSION" ]; then
                sed -i "s/\.plugins\.$PLUGIN_NAME\.version=$PLUGIN_CURRENT_VERSION/.plugins.$PLUGIN_NAME.version=$PLUGIN_LATEST_VERSION/g" "$HERE/compose.yaml"
                echo "Plugin $PLUGIN_NAME updated to $PLUGIN_LATEST_VERSION (you need to restart Traefik for this to take effect)"
            else
                echo "Plugin $PLUGIN_NAME already on latest ($PLUGIN_LATEST_VERSION)"
            fi
        done < <(echo "$PLUGIN_LINES" | grep -o '\.plugins\..*\.modulename=[^"]*')
        ;;

    backup-state)
        if [ ! -d "$STATE_DIR" ]; then
            echo "State directory not found: $STATE_DIR" >&2
            exit 1
        fi

        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        OUTPUT="$HERE/luna-backup-$TIMESTAMP.tar.gz"

        echo "Backing up $STATE_DIR and VARS.sh..."
        docker run --rm -v "$STATE_DIR":/backup/state:ro -v "$HERE/VARS.sh":/backup/VARS.sh:ro alpine tar czf - -C /backup . > "$OUTPUT"
        echo "Backup created: $OUTPUT"
        echo "Note: The backup contains VARS.sh which includes secrets. Store it securely."
        ;;

    prereqs)
        sudo apt-get update -qq

        if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
            printf "Installing Docker and Docker Compose..."
            sudo apt-get install -y docker.io docker-compose-v2 && echo " done" || { echo ""; echo "Docker install failed. Install manually: https://docs.docker.com/engine/install/" >&2; }
            sudo systemctl enable docker 2>/dev/null || true
            sudo systemctl start docker 2>/dev/null || true
        else
            echo "Docker already installed."
        fi

        for tool in yq envsubst jq curl; do
            if ! command -v "$tool" >/dev/null 2>&1; then
                printf "Installing %s..." "$tool"
                case "$tool" in
                    envsubst) pkg="gettext-base" ;;
                    *) pkg="$tool" ;;
                esac
                sudo apt-get install -y "$pkg" && echo " done" || echo " failed"
            else
                echo "$tool already installed."
            fi
        done

        echo ""
        ALL_OK=true
        for cmd in docker yq envsubst jq curl; do
            if command -v "$cmd" >/dev/null 2>&1; then
                echo "  [OK] $cmd"
            else
                echo "  [MISSING] $cmd"
                ALL_OK=false
            fi
        done
        if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
            echo "  [OK] docker compose"
        else
            echo "  [MISSING] docker compose"
            ALL_OK=false
        fi
        if [ "$ALL_OK" = true ]; then
            echo ""
            echo "All prerequisites installed."
        else
            echo ""
            echo "Some prerequisites are missing. Install them manually." >&2
            exit 1
        fi
        ;;

    *)
        echo "Usage: $0 <command>"
        echo ""
        echo "Commands:"
        echo "  prereqs                   Install prerequisites (docker, yq, envsubst, jq, curl)"
        echo "  install                   Install and start all services"
        echo "  restart <service>         Restart a single service"
        echo "  list-domains              List all required subdomains"
        echo "  backup-state               Back up state directory and VARS.sh"
        echo "  old-images                List Docker images older than 60 days"
        echo "  update-socket-proxy       Pull latest socket-proxy and restart if needed"
        echo "  update-traefik-plugins    Update Traefik plugin versions"
        exit 1
        ;;
esac
