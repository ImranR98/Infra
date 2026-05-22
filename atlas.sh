#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

get_sudo_cmd() {
    if command -v run0 &>/dev/null; then echo "run0"; else echo "sudo"; fi
}

detect_pkgmgr() {
    if command -v apt-get &>/dev/null; then echo "apt"
    elif command -v rpm-ostree &>/dev/null; then echo "rpm-ostree"
    elif command -v dnf &>/dev/null; then echo "dnf"
    else echo "unknown"
    fi
}

ensure_docker_repo() {
    local su="$1"
    local pkgmgr="$2"
    case "$pkgmgr" in
        apt)
            install_pkgs "$su" "$pkgmgr" curl gnupg
            $su install -m 0755 -d /etc/apt/keyrings
            os_id=$(. /etc/os-release && echo "${ID:-ubuntu}")
            os_codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
            case "$os_id" in
                debian) docker_distro="debian" ;;
                *)      docker_distro="ubuntu" ;;
            esac
            curl -fsSL "https://download.docker.com/linux/$docker_distro/gpg" | $su gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$docker_distro $os_codename stable" | $su tee /etc/apt/sources.list.d/docker.list >/dev/null
            $su "$pkgmgr" update -qq
            ;;
        dnf)
            $su "$pkgmgr" install -y dnf-plugins-core
            $su "$pkgmgr" config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            ;;
        rpm-ostree)
            $su rpm-ostree refresh-md
            ;;
    esac
}

install_pkgs() {
    local su="$1"
    local pkgmgr="$2"
    shift 2
    case "$pkgmgr" in
        apt) $su apt-get install -y "$@" || return 1 ;;
        dnf) $su dnf install -y "$@" || return 1 ;;
        rpm-ostree) $su rpm-ostree install --apply-live --assumeyes "$@" || return 1 ;;
        *) return 1 ;;
    esac
}

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

source "$HERE/lib/vars.sh"
if [ -f "$HERE/VARS.sh" ]; then
    source_env "$TARGET"
    DOCKER_GID="$(getent group docker | cut -d: -f3)"
    if [ -z "$DOCKER_GID" ]; then echo "Error: docker group not found. Is Docker installed?" >&2; exit 1; fi
    export DOCKER_GID
    export FRPC_USER="${TARGET,,}"
elif [ -n "$COMMAND" ]; then
    case "$COMMAND" in
        install|install-preboot|restart|backup-state|k3s)
            echo "No VARS.sh found. Create VARS.sh with variables from vars/VARS.common.sh and vars/VARS.$TARGET.sh." >&2
            exit 1
            ;;
    esac
fi

get_envsubst_vars() {
    local vars=""
    vars=$(grep -hEo '\$[A-Z_][A-Z_0-9]*|\$\{[A-Z_][A-Z_0-9]*\}' "$HERE"/compose/"$TARGET".compose.yaml 2>/dev/null | sed 's/[{}]//g' | sort -u | tr '\n' ' ')
    for f in "$HERE"/templates/"$TARGET"/*.yaml "$HERE"/templates/"$TARGET"/*.json "$HERE"/templates/"$TARGET"/*.txt "$HERE"/templates/"$TARGET"/*.toml; do
        [ -f "$f" ] && vars="$vars $(grep -hEo '\$[A-Z_][A-Z_0-9]*|\$\{[A-Z_][A-Z_0-9]*\}' "$f" 2>/dev/null | sed 's/[{}]//g' | tr '\n' ' ')"
    done
    vars=$(echo "$vars" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    for v in MY_UID DOCKER_GID FRPC_USER TARGET STATE_DIR; do
        case " $vars " in *" \$$v "*) ;; *) vars="$vars \$$v" ;; esac
    done
    echo "$vars"
}

generate_configs() {
    local target="$1"
    echo "=== Re/generate various state files ==="

    # IGNORE INITIALLY logic: on first install the state dir doesn't exist yet,
    # so PROTECT_INIT_ROUTES defaults to true and lines ending with
    # "# IGNORE INITIALLY" are commented out. On subsequent runs the existing
    # config is detected and routes are uncommented. Deleting the state dir
    # resets this — all routes go back to protected mode.
    if [ -f "$HERE/templates/$target/authelia.config.yaml" ]; then
        if [ -f "$STATE_DIR/authelia/config/configuration.yml" ]; then
            PROTECT_INIT_ROUTES=${PROTECT_INIT_ROUTES:-false}
        else
            PROTECT_INIT_ROUTES=${PROTECT_INIT_ROUTES:-true}
        fi
        echo "PROTECT_INIT_ROUTES=$PROTECT_INIT_ROUTES"
        if [ "$PROTECT_INIT_ROUTES" = true ]; then
            sed '/# IGNORE INITIALLY$/ s/^/# /' "$HERE"/templates/"$target"/authelia.config.yaml | envsubst "$ENVSUBST_VARS" >"$STATE_DIR"/authelia/config/configuration.yml
            echo "Note: the generated Authelia config does not include lines that end with \"# IGNORE INITIALLY\"."
        else
            envsubst "$ENVSUBST_VARS" < "$HERE"/templates/"$target"/authelia.config.yaml >"$STATE_DIR"/authelia/config/configuration.yml
        fi

        printf '%s\n' "$AUTHELIA_USERS_DATABASE" >"$STATE_DIR"/authelia/config/users_database.yml
    fi

    if [ -f "$HERE/templates/$target/traefik.dynamic-configuration.yaml" ]; then
        if [ ! -f "$STATE_DIR"/traefik/acme.json ]; then
            echo '{}' >"$STATE_DIR"/traefik/acme.json
            echo "Created an empty \"acme.json\"."
        fi
        chmod 600 "$STATE_DIR"/traefik/acme.json
        envsubst "$ENVSUBST_VARS" < "$HERE"/templates/"$target"/traefik.dynamic-configuration.yaml > "$STATE_DIR"/traefik/dynamic-configuration.yaml
    fi

    if [ -f "$HERE/templates/$target/plausible.clickhouse-config.xml" ]; then
        cp "$HERE"/templates/"$target"/plausible.clickhouse-config.xml "$STATE_DIR"/plausible/config/clickhouse-config.xml
    fi

    if [ -f "$HERE/templates/$target/frpc.toml" ]; then
        mkdir -p "$STATE_DIR"/frpc
        envsubst "$ENVSUBST_VARS" < "$HERE"/templates/"$target"/frpc.toml > "$STATE_DIR"/frpc/frpc.toml
        chmod 600 "$STATE_DIR"/frpc/frpc.toml
    fi

    if [ -f "$HERE/templates/$target/frps-tokens.txt" ]; then
        mkdir -p "$STATE_DIR"/frps
        envsubst "$ENVSUBST_VARS" < "$HERE"/templates/"$target"/frps-tokens.txt > "$STATE_DIR"/frps/tokens.txt
        chmod 600 "$STATE_DIR"/frps/tokens.txt
    fi

    echo "=== Generate Logtfy config ==="
    if [ -f "$HERE/templates/$target/logtfy.config.json" ]; then
        mkdir -p "$STATE_DIR"/logtfy
        envsubst "$ENVSUBST_VARS" < "$HERE"/templates/"$target"/logtfy.config.json > "$STATE_DIR"/logtfy/config.json
        echo "Done."
    else
        echo "No logtfy config template found. Skipping."
    fi
}

export ENVSUBST_VARS="$(get_envsubst_vars)"

case "$COMMAND" in
    install)
        echo "=== Create Required Directories ==="
        tmpfile="$(mktemp)"
        trap 'rm -f "$tmpfile"' EXIT INT TERM
        envsubst "$ENVSUBST_VARS" < "$HERE"/compose/"$TARGET".compose.yaml > "$tmpfile"
        while IFS=: read -r host_path _; do
                name="$(basename "$host_path")"
                if [[ "$name" =~ \.[a-zA-Z0-9]{1,5}$ ]]; then
                    mkdir -p "$(dirname "$host_path")"
                    [ "$UID" -eq 0 ] && chown "$MY_UID:$MY_UID" "$(dirname "$host_path")" 2>/dev/null || :
                else
                    mkdir -p "$host_path"
                    [ "$UID" -eq 0 ] && chown "$MY_UID:$MY_UID" "$host_path" 2>/dev/null || :
                fi
            done < <(STATE_DIR_ESC=$(printf '%s\n' "$STATE_DIR" | sed 's|[][.^$*+?(){|\\]|\\&|g'); sed -n "s|^[[:space:]]*- \"\?$STATE_DIR_ESC/\([^\":]*\)\"\?:.*$|$STATE_DIR/\1|p" "$tmpfile")
        echo "Done."

        generate_configs "$TARGET"

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
        SU=$(get_sudo_cmd)
        $SU bash -c "mv '$STATE_DIR'/$TARGET.service /etc/systemd/system/$TARGET.service"
        command -v chcon &>/dev/null && $SU chcon -t systemd_unit_file_t /etc/systemd/system/$TARGET.service 2>/dev/null || true
        $SU systemctl daemon-reload && $SU systemctl enable $TARGET.service
        $SU systemctl stop $TARGET.service 2>/dev/null || true
        sleep 5
        $SU systemctl start $TARGET.service
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
        envsubst "$ENVSUBST_VARS" < "$HERE"/templates/"$TARGET"/frpc-preboot.toml > "$STATE_DIR"/frpc/frpc-preboot.toml
        chmod 600 "$STATE_DIR"/frpc/frpc-preboot.toml
        echo "Done."

        echo "=== Check if root partition is LUKS-encrypted ==="
        if bash "$HERE"/scripts/check_root_luks.sh; then
            echo "LUKS detected. Installing preboot FRPC and dracut-crypt-ssh..."
            $(get_sudo_cmd) bash "$HERE"/scripts/dracut-crypt-ssh.install.sh "${SUDO_USER:-$USER}"
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
        if [ -n "${2:-}" ]; then
            generate_configs "$TARGET"
            envsubst "$ENVSUBST_VARS" < "$HERE"/compose/"$TARGET".compose.yaml > "$STATE_DIR"/compose.yaml
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
            $(get_sudo_cmd) systemctl restart "$TARGET"
        else
            echo "wollomatic/socket-proxy:1 is already the latest (only the :1 tag is tracked)."
        fi
        ;;

    list-domains)
        if [ "$TARGET" = "sol" ]; then
            make -C "$HERE/k3s/$TARGET" domains
        else
            sed -n 's/.*Host(`\([^`]*\)`).*/\1/p' "$HERE"/compose/"$TARGET".compose.yaml | sort -u | envsubst "$ENVSUBST_VARS"
        fi
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
            PLUGIN_LATEST_VERSION="$(curl -s "https://api.github.com/repos/$(echo "$PLUGIN_URL" | sed 's|github\.com/||')/releases/latest" | jq -r '.tag_name')"
            if [ "$PLUGIN_CURRENT_VERSION" != "$PLUGIN_LATEST_VERSION" ]; then
                sed -i "s/\.plugins\.$PLUGIN_NAME\.version=$PLUGIN_CURRENT_VERSION/.plugins.$PLUGIN_NAME.version=$PLUGIN_LATEST_VERSION/g" "$HERE/compose/$TARGET.compose.yaml"
                echo "Plugin $PLUGIN_NAME updated to $PLUGIN_LATEST_VERSION (you need to restart Traefik for this to take effect)."
            else
                echo "Plugin $PLUGIN_NAME already the latest ($PLUGIN_LATEST_VERSION)."
            fi
        done < <(echo "$PLUGIN_LINES" | grep -o '\.plugins\..*\.modulename=[^"]*')
        ;;

    update-frp)
        if [ "$TARGET" != "sol" ]; then
            echo "This command must be run on the sol target." >&2
            exit 1
        fi

        if ! docker system info 2>/dev/null | grep -q "Username"; then
            echo "Not logged into Docker Hub. Run 'docker login' first." >&2
            exit 1
        fi

        current_ver="$(sed -n 's/.*image: fatedier\/frpc:v\([^"]*\).*/\1/p' "$HERE/compose/sol.compose.yaml")"
        if [ -z "$current_ver" ]; then
            echo "Could not determine current FRPC version from sol.compose.yaml." >&2
            exit 1
        fi
        echo "Current FRPC version: v$current_ver"

        latest_tag="$(curl -s https://api.github.com/repos/fatedier/frp/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')"
        latest_ver="${latest_tag#v}"
        echo "Latest FRP version:  v$latest_ver"

        if [ "$current_ver" = "$latest_ver" ]; then
            echo "FRPC is already at the latest version."
            exit 0
        fi

        echo "Updating sol.compose.yaml..."
        sed -i "s|image: fatedier/frpc:v$current_ver|image: fatedier/frpc:v$latest_ver|" "$HERE/compose/sol.compose.yaml"

        echo "Updating lens.compose.yaml..."
        sed -i "s|image: imranrdev/frps-with-multiuser:latest|image: imranrdev/frps-with-multiuser:v$latest_ver|" "$HERE/compose/lens.compose.yaml"

        echo "=== Build frps-with-multiuser:v$latest_ver ==="
        TMPDIR="$(mktemp -d)"
        trap 'rm -rf "$TMPDIR"' EXIT INT TERM
        git clone https://github.com/ImranR98/frps-with-multiuser-docker.git "$TMPDIR"
        cd "$TMPDIR"
        docker build --no-cache . --network host -t "imranrdev/frps-with-multiuser:v$latest_ver"
        docker push "imranrdev/frps-with-multiuser:v$latest_ver"
        echo "=== Done ==="

        echo ""
        echo "FRPC updated from v$current_ver to v$latest_ver."
        echo "Compose files updated and image pushed to Docker Hub."
        echo ""
        echo "Next steps:"
        echo "  1. Commit and push the changes."
        echo "  2. On lens, pull the repo and restart the frps-with-multiuser container."
        echo "  3. On sol, restart the frpc container."
        echo ""
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
        (umask 0077; docker run --rm -v "$STATE_DIR":/backup/state:ro -v "$HERE/VARS.sh":/backup/VARS.sh:ro \
            alpine sh -c 'apk add --no-cache tar >/dev/null 2>&1 && exec tar cf - --ignore-failed-read --warning=no-file-changed --warning=no-file-removed -C /backup .' > "$OUTPUT")
        if [ -s "$OUTPUT" ]; then
            echo "Backup created: $OUTPUT"
            BACKUP_RETENTION=${BACKUP_RETENTION:-1}
            if [ "$BACKUP_RETENTION" -gt 0 ]; then
                old_backups=()
                while IFS= read -r -d '' f; do
                    old_backups+=("$f")
                done < <(find "$BACKUP_DIR" -maxdepth 1 -name "$TARGET-backup-*.tar" -printf '%T@ %p\0' | sort -rnz | cut -z -d' ' -f2- | tail -n +$((BACKUP_RETENTION + 1)))
                for old in "${old_backups[@]}"; do
                    rm -f "$old"
                    echo "Pruned old backup: $old"
                done
            fi
            echo "Note: The backup contains VARS.sh which includes secrets. Store it securely."
        else
            echo "Backup failed" >&2
            rm -f "$OUTPUT"
            exit 1
        fi
        ;;

    prereqs)
        SU=$(get_sudo_cmd)
        PKG_MGR=$(detect_pkgmgr)

        case "$PKG_MGR" in
            apt) $SU apt-get update -qq ;;
            dnf) $SU dnf check-update -q || true ;;
            rpm-ostree) $SU rpm-ostree refresh-md ;;
        esac

        if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
            printf "Installing Docker and Docker Compose..."
            ensure_docker_repo "$SU" "$PKG_MGR"
            if [ "$PKG_MGR" = "rpm-ostree" ]; then
                $SU rpm-ostree install --apply-live --assumeyes docker-ce docker-ce-cli containerd.io docker-compose-plugin && echo " done" || { echo ""; echo "Docker install failed. Install manually: https://docs.docker.com/engine/install/" >&2; }
            else
                install_pkgs "$SU" "$PKG_MGR" docker-ce docker-ce-cli containerd.io docker-compose-plugin && echo " done" || { echo ""; echo "Docker install failed. Install manually: https://docs.docker.com/engine/install/" >&2; }
            fi
            $SU systemctl enable docker 2>/dev/null || true
            $SU systemctl start docker 2>/dev/null || true
        else
            echo "Docker already installed."
        fi

        ALL_OK=true
        for tool in yq envsubst jq curl python3 skopeo; do
            if ! command -v "$tool" >/dev/null 2>&1; then
                printf "Installing %s..." "$tool"
                case "$tool" in
                    envsubst)
                        case "$PKG_MGR" in
                            apt) pkg="gettext-base" ;;
                            dnf|rpm-ostree) pkg="gettext" ;;
                        esac
                        ;;
                    python3)
                        case "$PKG_MGR" in
                            apt) pkg="python3" ;;
                            dnf|rpm-ostree) pkg="python3" ;;
                        esac
                        ;;
                    *) pkg="$tool" ;;
                esac
                install_pkgs "$SU" "$PKG_MGR" "$pkg" && echo " done" || { echo " failed"; ALL_OK=false; }
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

        if ! python3 -c "import yaml" >/dev/null 2>&1; then
            printf "Installing python3-yaml..."
            case "$PKG_MGR" in
                apt) pkg="python3-yaml" ;;
                dnf) pkg="python3-pyyaml" ;;
                rpm-ostree) pkg="python3-pyyaml" ;;
                *) pkg="" ;;
            esac
            if [ -n "$pkg" ] && install_pkgs "$SU" "$PKG_MGR" "$pkg" >/dev/null 2>&1; then
                echo " done"
            else
                echo " failed"
                ALL_OK=false
            fi
            if python3 -c "import yaml" >/dev/null 2>&1; then
                echo "  [OK] python3-yaml"
            else
                echo "  [MISSING] python3-yaml"
                ALL_OK=false
            fi
        else
            echo "python3-yaml already installed."
            echo "  [OK] python3-yaml"
        fi

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

    k3s)
        if [ ! -d "$HERE/k3s/$TARGET" ]; then
            echo "No K3s manifests found for target '$TARGET'." >&2
            exit 1
        fi
        make -C "$HERE/k3s/$TARGET" ${2:+"$2"}
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
        echo "  prereqs                   Install prerequisites (docker, yq, envsubst, jq, curl, python3, python3-yaml, skopeo)"
        echo "  install                   Install and start all services"
        echo "  install-preboot           Install preboot FRPC in initramfs (for remote LUKS unlock)"
        echo "  k3s [target]              Run K3s Make target (base, apps, validate, etc.)"
        echo "  restart <service>         Restart a single service"
        echo "  list-domains              List all required subdomains"
        echo "  backup-state              Back up state directory and VARS.sh"
        echo "  old-images                List Docker images older than 60 days"
        echo "  update-socket-proxy       Pull latest socket-proxy and restart if needed"
        echo "  update-traefik-plugins    Update Traefik plugin versions"
        echo "  update-frp              Check FRPC version on sol, update compose files, build and push frps image"
        exit 1
        ;;

    *)
        echo "Unknown command: $COMMAND" >&2
        exit 1
        ;;
esac
