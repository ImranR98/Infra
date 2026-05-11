#!/bin/bash
set -euo pipefail

HERE_LX1A="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE_LX1A"/prep_env.sh

printTitle "Pre-install Sanity Checks"
FAILED=false
for cmd in docker yq envsubst; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Required command not found: $cmd" >&2
        FAILED=true
    fi
done
for var in STATE_DIR MAIN_PARENT_DIR SERVICES_DOMAIN DOMAIN_OWNER_EMAIL AUTHELIA_USERS_DATABASE PLAUSIBLE_SECRET_KEY; do
    if [ -z "${!var:-}" ]; then
        echo "Required variable is empty or not set: $var" >&2
        FAILED=true
    fi
done
if [ "$FAILED" = true ]; then
    exit 1
fi
echo "All checks passed."
printLine -

printTitle "Create Required Directories"
tmpfile="$(mktemp)"
envsubst < "$HERE_LX1A"/landscape.docker-compose.yaml > "$tmpfile"
for prefix in "$STATE_DIR" "$MAIN_PARENT_DIR"; do
    yq '.services[] | .volumes[] | select(type == "string")' "$tmpfile" 2>/dev/null | \
        while IFS=: read -r host_path _; do
            case "$host_path" in
                "$prefix"/*)
                    if [[ "$(basename "$host_path")" == *.* ]]; then
                        mkdir -p "$(dirname "$host_path")" 2>/dev/null || :
                    else
                        mkdir -p "$host_path" 2>/dev/null || :
                    fi
                    ;;
            esac
        done
done
rm -f "$tmpfile"
mkdir -p "$STATE_DIR/logtfy" "$STATE_DIR/traefik_logs"
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
    sed '/# IGNORE INITIALLY$/ s/^/# /' "$HERE_LX1A"/files/authelia.config.yaml | envsubst >"$STATE_DIR"/authelia/config/configuration.yml
    echo "Note that the generated Authelia config does not include lines that end with \"# IGNORE INITIALLY\"."
else
    envsubst < "$HERE_LX1A"/files/authelia.config.yaml >"$STATE_DIR"/authelia/config/configuration.yml
fi

echo "$AUTHELIA_USERS_DATABASE" >"$STATE_DIR"/authelia/config/users_database.yml
if [ ! -f "$STATE_DIR"/traefik/acme.json ]; then
    echo '{}' >"$STATE_DIR"/traefik/acme.json
    echo "Created an empty \"acme.json\"."
fi
chmod 600 "$STATE_DIR"/traefik/acme.json
envsubst < "$HERE_LX1A"/files/traefik.dynamic-configuration.yaml > "$STATE_DIR"/traefik/dynamic-configuration.yaml
envsubst < "$HERE_LX1A"/files/logtfy.json > "$STATE_DIR"/logtfy/config.json
echo "Done."

printTitle "Generate Docker Compose file"
envsubst < "$HERE_LX1A"/landscape.docker-compose.yaml > "$STATE_DIR"/landscape.docker-compose.yaml
echo "Done."

printTitle "Install and start the Landscape service"
generateComposeService landscape "$MY_UID" >"$STATE_DIR"/landscape.service
awk -v SCRIPT_DIR="$STATE_DIR" '{gsub("path_to_here", SCRIPT_DIR); print}' "$STATE_DIR"/landscape.service >"$STATE_DIR"/landscape.service.temp
mv "$STATE_DIR"/landscape.service.temp "$STATE_DIR"/landscape.service
$SUDO_COMMAND bash -c "mv '$STATE_DIR'/landscape.service /etc/systemd/system/landscape.service && \
    chcon -t systemd_unit_file_t /etc/systemd/system/landscape.service 2>/dev/null || true && \
    systemctl daemon-reload && systemctl enable landscape.service && \
    systemctl stop landscape.service 2>/dev/null || true && sleep 5 && systemctl start landscape.service"
echo "Done."

printTitle "Finished"
echo "Note:
- Some services may need manual setup in their respective GUIs."
printLine -
