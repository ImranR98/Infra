#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

case "${1:-}" in
    luna|lens|sol)
        export TARGET="$1"
        shift
        ;;
    "")
        echo "Usage: $0 <target> <command>" >&2
        echo "Run '$0 <target>' to see available commands." >&2
        exit 1
        ;;
    *)
        echo "Unknown target: $1" >&2
        echo "Valid targets: luna, lens, sol" >&2
        exit 1
        ;;
esac

COMMAND="${1:-}"

export STATE_DIR="$HERE/state"

if [ -f "$HERE/VARS.sh" ]; then
    while IFS= read -r var; do
        if ! grep -q "^export $var=" "$HERE/VARS.sh"; then
            echo "VARS.sh is missing required variable: $var" >&2
            exit 1
        fi
    done < <(grep -hEo '^export [^=]+' "$HERE"/vars/VARS.common.sh "$HERE"/vars/VARS."$TARGET".sh | sed 's/^export //' | sort -u)
    source "$HERE/VARS.sh"
    if [ "$UID" -eq 0 ]; then
        export MY_UID=1000
    else
        export MY_UID="$UID"
    fi
    export DOCKER_GID="$(grep docker /etc/group | awk -F: '{print $3}')"
    export FRPC_USER="${TARGET,,}"
elif [ -n "$COMMAND" ] && [ "$COMMAND" != "prereqs" ] && [ "$COMMAND" != "list-domains" ] && [ "$COMMAND" != "old-images" ] && [ "$COMMAND" != "update-socket-proxy" ] && [ "$COMMAND" != "update-traefik-plugins" ]; then
    echo "No VARS.sh found. Create VARS.sh with variables from vars/VARS.common.sh and vars/VARS.$TARGET.sh." >&2
    exit 1
fi

case "$COMMAND" in
    install)
        echo "=== Create Required Directories ==="
        tmpfile="$(mktemp)"
        envsubst < "$HERE"/compose/"$TARGET".compose.yaml > "$tmpfile"
        sed -n "s|^[[:space:]]*- \"\?$STATE_DIR/\([^:]*\):.*$|$STATE_DIR/\1|p" "$tmpfile" | \
            while IFS=: read -r host_path _; do
                name="$(basename "$host_path")"
                if [[ "$name" =~ \.[a-zA-Z0-9]{1,5}$ ]]; then
                    mkdir -p "$(dirname "$host_path")" 2>/dev/null || :
                    [ "$UID" -eq 0 ] && chown "$MY_UID:$MY_UID" "$(dirname "$host_path")" 2>/dev/null || :
                else
                    mkdir -p "$host_path" 2>/dev/null || :
                    [ "$UID" -eq 0 ] && chown "$MY_UID:$MY_UID" "$host_path" 2>/dev/null || :
                fi
            done
        echo "Done."

        echo "=== Re/generate various state files ==="

        if [ -f "$HERE/templates/$TARGET/authelia.config.yaml" ]; then
            if [ -f "$STATE_DIR/authelia/config/configuration.yml" ]; then
                PROTECT_INIT_ROUTES=${PROTECT_INIT_ROUTES:-false}
            else
                PROTECT_INIT_ROUTES=${PROTECT_INIT_ROUTES:-true}
            fi
            echo "PROTECT_INIT_ROUTES=$PROTECT_INIT_ROUTES"
            if [ "$PROTECT_INIT_ROUTES" = true ]; then
                sed '/# IGNORE INITIALLY$/ s/^/# /' "$HERE"/templates/"$TARGET"/authelia.config.yaml | envsubst >"$STATE_DIR"/authelia/config/configuration.yml
                echo "Note: the generated Authelia config does not include lines that end with \"# IGNORE INITIALLY\"."
            else
                envsubst < "$HERE"/templates/"$TARGET"/authelia.config.yaml >"$STATE_DIR"/authelia/config/configuration.yml
            fi

            echo "$AUTHELIA_USERS_DATABASE" >"$STATE_DIR"/authelia/config/users_database.yml
        fi

        if [ -f "$HERE/templates/$TARGET/traefik.dynamic-configuration.yaml" ]; then
            if [ ! -f "$STATE_DIR"/traefik/acme.json ]; then
                echo '{}' >"$STATE_DIR"/traefik/acme.json
                echo "Created an empty \"acme.json\"."
            fi
            chmod 600 "$STATE_DIR"/traefik/acme.json
            envsubst < "$HERE"/templates/"$TARGET"/traefik.dynamic-configuration.yaml > "$STATE_DIR"/traefik/dynamic-configuration.yaml
        fi

        if [ -f "$HERE/templates/$TARGET/plausible.clickhouse-config.xml" ]; then
            cp "$HERE"/templates/"$TARGET"/plausible.clickhouse-config.xml "$STATE_DIR"/plausible/config/clickhouse-config.xml
        fi

        if [ -f "$HERE/templates/$TARGET/frpc.toml" ]; then
            mkdir -p "$STATE_DIR"/frpc
            envsubst < "$HERE"/templates/"$TARGET"/frpc.toml > "$STATE_DIR"/frpc/frpc.toml
        fi

        if [ -f "$HERE/templates/$TARGET/frps-tokens.txt" ]; then
            mkdir -p "$STATE_DIR"/frps
            envsubst < "$HERE"/templates/"$TARGET"/frps-tokens.txt > "$STATE_DIR"/frps/tokens.txt
        fi

        echo "=== Generate Logtfy config ==="
        if [ -f "$HERE/templates/$TARGET/logtfy.config.json" ]; then
            mkdir -p "$STATE_DIR"/logtfy
            envsubst < "$HERE"/templates/"$TARGET"/logtfy.config.json > "$STATE_DIR"/logtfy/config.json
            echo "Done."
        else
            echo "No logtfy config template found. Skipping."
        fi

        echo "=== Generate Docker Compose file ==="
        cp "$tmpfile" "$STATE_DIR"/compose.yaml
        rm -f "$tmpfile"
        echo "Done."

        echo "=== Install and start the $TARGET service ==="
        cat > "$STATE_DIR"/"$TARGET".service << EOF
[Unit]
Description=$TARGET start
StartLimitIntervalSec=0

[Service]
User=$UID
Type=simple
ExecStart=/usr/bin/docker compose -p $TARGET -f $STATE_DIR/compose.yaml up
ExecStop=/usr/bin/docker compose -p $TARGET -f $STATE_DIR/compose.yaml down
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
        sudo bash -c "mv '$STATE_DIR'/$TARGET.service /etc/systemd/system/$TARGET.service && \
            chcon -t systemd_unit_file_t /etc/systemd/system/$TARGET.service 2>/dev/null || true && \
            systemctl daemon-reload && systemctl enable $TARGET.service && \
            systemctl stop $TARGET.service 2>/dev/null || true && sleep 5 && systemctl start $TARGET.service"
        echo "Done."

        echo "=== Finished ==="
        echo "Note: Some services may need manual setup in their respective GUIs."
        echo ""
        ;;

    install-preboot)
        if [ ! -f "$HERE/templates/$TARGET/frpc-preboot.toml" ]; then
            echo "No preboot template found for target $TARGET." >&2
            exit 1
        fi

        echo "=== Generate preboot FRPC config ==="
        mkdir -p "$STATE_DIR"/frpc
        envsubst < "$HERE"/templates/"$TARGET"/frpc-preboot.toml > "$STATE_DIR"/frpc/frpc-preboot.toml
        echo "Done."

        echo "=== Check if root partition is LUKS-encrypted ==="
        if bash "$HERE"/scripts/check_root_luks.sh; then
            echo "LUKS detected. Installing preboot FRPC and dracut-crypt-ssh..."
            sudo bash "$HERE"/scripts/dracut-crypt-ssh.install.sh "$USER"
            bash "$HERE"/scripts/frpc-preboot.install.sh "$STATE_DIR"
            echo ""
            echo "Preboot FRPC installed. The initramfs has been rebuilt."
            echo "On the next boot, FRPC will start before root is mounted,"
            echo "tunneling SSH to the FRPS server on port 8887."
        else
            echo "Root partition is not LUKS-encrypted. Skipping preboot setup."
            echo "If you add LUKS later, re-run this command."
        fi
        ;;

    restart)
        envsubst < "$HERE"/compose/"$TARGET".compose.yaml > "$STATE_DIR"/compose.yaml

        if [ -n "${2:-}" ]; then
            docker compose -p "$TARGET" -f "$STATE_DIR"/compose.yaml down "$2" || :
            docker compose -p "$TARGET" -f "$STATE_DIR"/compose.yaml up -d "$2"
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
        echo "=== Pull Latest 'wollomatic/socket-proxy:1' and Restart $TARGET if Needed ==="

        OLDSPHASH="$(docker images wollomatic/socket-proxy:1 --format '{{.ID}}')"
        docker pull wollomatic/socket-proxy:1
        NEWSPHASH="$(docker images wollomatic/socket-proxy:1 --format '{{.ID}}')"

        if [ "$OLDSPHASH" != "$NEWSPHASH" ]; then
            read -p "New image pulled. Press enter to restart $TARGET..." NOTHING
            sudo systemctl restart "$TARGET"
        else
            echo "wollomatic/socket-proxy:1 is already the latest (only the :1 tag is tracked)."
        fi
        ;;

    list-domains)
        sed -n 's/.*Host(`\([^`]*\)`).*/\1/p' "$HERE"/compose/"$TARGET".compose.yaml | sort -u | envsubst
        ;;

    update-traefik-plugins)
        for cmd in yq jq; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                echo "$cmd is required but not installed." >&2
                exit 1
            fi
        done

        PLUGIN_LINES="$(yq '.services.traefik.command' "$HERE/compose/$TARGET.compose.yaml")"

        while IFS= read -r l; do
            PLUGIN_URL="$(echo "$l" | awk -F= '{print $NF}')"
            if ! echo "$PLUGIN_URL" | grep -q 'github.com/'; then
                echo "UNSUPPORTED PLUGIN: $PLUGIN_URL" >&2
                continue
            fi
            PLUGIN_NAME="$(echo "$l" | awk -F. '{print $3}')"
            PLUGIN_CURRENT_VERSION="$(echo "$PLUGIN_LINES" | grep -o "\.plugins\.$PLUGIN_NAME\.version=[^\"]*" | awk -F= '{print $NF}')"
            PLUGIN_LATEST_VERSION="$(curl -s "https://api.github.com/repos$(echo "$PLUGIN_URL" | sed 's|github\.com/||')/releases/latest" | jq -r '.tag_name')"
            if [ "$PLUGIN_CURRENT_VERSION" != "$PLUGIN_LATEST_VERSION" ]; then
                sed -i "s/\.plugins\.$PLUGIN_NAME\.version=$PLUGIN_CURRENT_VERSION/.plugins.$PLUGIN_NAME.version=$PLUGIN_LATEST_VERSION/g" "$HERE/compose/$TARGET.compose.yaml"
                echo "Plugin $PLUGIN_NAME updated to $PLUGIN_LATEST_VERSION (you need to restart Traefik for this to take effect)."
            else
                echo "Plugin $PLUGIN_NAME already the latest ($PLUGIN_LATEST_VERSION)."
            fi
        done < <(echo "$PLUGIN_LINES" | grep -o '\.plugins\..*\.modulename=[^"]*')
        ;;

    backup-state)
        if [ ! -d "$STATE_DIR" ]; then
            echo "State directory not found: $STATE_DIR" >&2
            exit 1
        fi

        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        BACKUP_DIR="$HERE/backup"
        mkdir -p "$BACKUP_DIR"
        OUTPUT="$BACKUP_DIR/$TARGET-backup-$TIMESTAMP.tar"

        echo "Backing up $STATE_DIR and VARS.sh..."
        docker run --rm -v "$STATE_DIR":/backup/state:ro -v "$HERE/VARS.sh":/backup/VARS.sh:ro \
            alpine sh -c 'apk add --no-cache tar >/dev/null 2>&1 && exec tar cf - --ignore-failed-read --warning=no-file-changed --warning=no-file-removed -C /backup .' > "$OUTPUT"
        if [ -s "$OUTPUT" ]; then
            echo "Backup created: $OUTPUT"
            for f in "$BACKUP_DIR"/"$TARGET"-backup-*.tar; do
                [ ! -e "$f" ] && continue
                [ "$f" = "$OUTPUT" ] && continue
                rm -f "$f"
            done
            echo "Note: The backup contains VARS.sh which includes secrets. Store it securely."
        else
            echo "Backup failed" >&2
            rm -f "$OUTPUT"
            exit 1
        fi
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

        ALL_OK=true
        for tool in yq envsubst jq curl; do
            if ! command -v "$tool" >/dev/null 2>&1; then
                printf "Installing %s..." "$tool"
                case "$tool" in
                    envsubst) pkg="gettext-base" ;;
                    *) pkg="$tool" ;;
                esac
                sudo apt-get install -y "$pkg" && echo " done" || { echo " failed"; ALL_OK=false; }
            else
                echo "$tool already installed."
            fi
            if command -v "$tool" >/dev/null 2>&1; then
                echo "  [OK] $tool"
            else
                echo "  [MISSING] $tool"
                ALL_OK=false
            fi
        done

        if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
            echo "  [OK] docker"
            echo "  [OK] docker compose"
        else
            echo "  [MISSING] docker or docker compose"
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

    "")
        echo "Usage: $0 <target> <command>"
        echo ""
        echo "Targets:"
        echo "  luna"
        echo "  lens"
        echo "  sol"
        echo ""
        echo "Commands:"
        echo "  prereqs                   Install prerequisites (docker, yq, envsubst, jq, curl)"
        echo "  install                   Install and start all services"
        echo "  install-preboot           Install preboot FRPC in initramfs (for remote LUKS unlock)"
        echo "  restart <service>         Restart a single service"
        echo "  list-domains              List all required subdomains"
        echo "  backup-state              Back up state directory and VARS.sh"
        echo "  old-images                List Docker images older than 60 days"
        echo "  update-socket-proxy       Pull latest socket-proxy and restart if needed"
        echo "  update-traefik-plugins    Update Traefik plugin versions"
        exit 1
        ;;

    *)
        echo "Unknown command: $COMMAND" >&2
        exit 1
        ;;
esac
