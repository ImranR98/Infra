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

generateComposeService() {
    echo "[Unit]
Description=$1 start
StartLimitIntervalSec=0

[Service]
User=$2
Type=idle
ExecStart=/usr/bin/docker compose -p $1 -f $3/compose.yaml up
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target"
}

export SUDO_COMMAND="sudo"
if command -v run0 >/dev/null 2>&1; then
    export SUDO_COMMAND="run0"
fi

if [ -f "$HERE/VARS.sh" ]; then
    while IFS= read -r var; do
        if ! grep -q "^export $var=" "$HERE/VARS.sh"; then
            echo "VARS.sh is missing required variable: $var" >&2
            exit 1
        fi
    done < <(grep -Eo '^export [^=]+' "$HERE"/template.VARS.sh | sed 's/^export //')
    source "$HERE/VARS.sh"
    export MY_UID="$UID"
    export NODE_NAME_LOWERCASE="${NODE_NAME,,}"
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
        generateComposeService luna "$MY_UID" "$STATE_DIR" >"$STATE_DIR"/luna.service
        $SUDO_COMMAND bash -c "mv '$STATE_DIR'/luna.service /etc/systemd/system/luna.service && \
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
            $SUDO_COMMAND systemctl restart luna
        else
            echo "Note that this script will only detect updates if the tag \"wollomatic/socket-proxy:1\" (major version 1) has not changed."
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
        echo "================================================"
        echo "Detecting package manager"
        echo "================================================"

        if command -v apt-get >/dev/null 2>&1; then
            PKG_MANAGER="apt"
            PKG_INSTALL="$SUDO_COMMAND apt-get install -y"
            PKG_UPDATE="$SUDO_COMMAND apt-get update -qq"
            echo "Detected: apt (Debian/Ubuntu)"
        elif command -v dnf >/dev/null 2>&1; then
            PKG_MANAGER="dnf"
            PKG_INSTALL="$SUDO_COMMAND dnf install -y"
            PKG_UPDATE="$SUDO_COMMAND dnf check-update"
            echo "Detected: dnf (Fedora/RHEL)"
        elif command -v pacman >/dev/null 2>&1; then
            PKG_MANAGER="pacman"
            PKG_INSTALL="$SUDO_COMMAND pacman -S --noconfirm"
            PKG_UPDATE="$SUDO_COMMAND pacman -Sy"
            echo "Detected: pacman (Arch)"
        elif command -v zypper >/dev/null 2>&1; then
            PKG_MANAGER="zypper"
            PKG_INSTALL="$SUDO_COMMAND zypper install -y"
            PKG_UPDATE="$SUDO_COMMAND zypper refresh"
            echo "Detected: zypper (openSUSE)"
        elif command -v apk >/dev/null 2>&1; then
            PKG_MANAGER="apk"
            PKG_INSTALL="$SUDO_COMMAND apk add"
            PKG_UPDATE="$SUDO_COMMAND apk update"
            echo "Detected: apk (Alpine)"
        elif command -v brew >/dev/null 2>&1; then
            PKG_MANAGER="brew"
            PKG_INSTALL="brew install"
            PKG_UPDATE="brew update"
            echo "Detected: brew (macOS)"
        else
            echo "Unsupported package manager." >&2
            echo "Install prerequisites manually: docker, yq (mikefarah/yq), envsubst (gettext), jq, curl" >&2
            exit 1
        fi

        get_pkg_name() {
            case "$1" in
                envsubst)
                    case "$PKG_MANAGER" in
                        apt) echo "gettext-base" ;;
                        zypper) echo "gettext-tools" ;;
                        *) echo "gettext" ;;
                    esac
                    ;;
                *) echo "$1" ;;
            esac
        }

        echo ""
        echo "================================================"
        echo "Installing prerequisites"
        echo "================================================"

        install_docker() {
            case "$PKG_MANAGER" in
                apt)
                    $PKG_UPDATE
                    $PKG_INSTALL docker.io docker-compose-v2 && return 0
                    $PKG_INSTALL docker-ce docker-ce-cli docker-compose-plugin && return 0
                    ;;
                dnf|pacman|zypper|apk)
                    $PKG_INSTALL docker docker-compose && return 0
                    ;;
                brew)
                    brew install docker docker-compose && return 0
                    ;;
            esac
            return 1
        }

        if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
            printf "Installing Docker and Docker Compose..."
            if install_docker; then
                echo " done"
                $SUDO_COMMAND systemctl enable docker 2>/dev/null || true
                $SUDO_COMMAND systemctl start docker 2>/dev/null || true
            else
                echo ""
                echo "Docker auto-install failed. Install manually:" >&2
                echo "  https://docs.docker.com/engine/install/" >&2
            fi
        else
            echo "Docker already installed."
        fi

        if ! command -v brew >/dev/null 2>&1; then
            for p in /home/linuxbrew/.linuxbrew/bin/brew /opt/homebrew/bin/brew /usr/local/bin/brew; do
                if [ -f "$p" ]; then
                    eval "$("$p" shellenv)"
                    break
                fi
            done
        fi

        if ! command -v brew >/dev/null 2>&1; then
            echo "Installing Homebrew..."
            NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true
            for p in /home/linuxbrew/.linuxbrew/bin/brew /opt/homebrew/bin/brew /usr/local/bin/brew; do
                if [ -f "$p" ]; then
                    eval "$("$p" shellenv)"
                    break
                fi
            done
            if command -v brew >/dev/null 2>&1; then echo "Homebrew installed."; else echo "Homebrew install failed." >&2; fi
        else
            echo "Homebrew already available."
        fi

        if ! command -v yq >/dev/null 2>&1; then
            printf "Installing yq..."
            brew install yq && echo " done" || echo " failed"
        else
            echo "yq already installed."
        fi

        for tool in envsubst jq curl; do
            if ! command -v "$tool" >/dev/null 2>&1; then
                printf "Installing %s..." "$tool"
                $PKG_INSTALL "$(get_pkg_name "$tool")" && echo " done" || echo " failed"
            else
                echo "$tool already installed."
            fi
        done

        echo ""
        echo "================================================"
        echo "Verification"
        echo "================================================"
        ALL_OK=true
        for cmd in docker yq envsubst jq curl; do
            if command -v "$cmd" >/dev/null 2>&1; then
                echo "  [OK] $cmd"
            else
                echo "  [MISSING] $cmd"
                ALL_OK=false
            fi
        done
        if command -v docker >/dev/null 2>&1; then
            if docker compose version >/dev/null 2>&1; then
                echo "  [OK] docker compose"
            else
                echo "  [MISSING] docker compose plugin"
                ALL_OK=false
            fi
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
