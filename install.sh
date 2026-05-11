#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE"/prep_env.sh

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
envsubst < "$HERE"/compose.yaml > "$tmpfile"
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
    sed '/# IGNORE INITIALLY$/ s/^/# /' "$HERE"/files/authelia.config.yaml | envsubst >"$STATE_DIR"/authelia/config/configuration.yml
    echo "Note that the generated Authelia config does not include lines that end with \"# IGNORE INITIALLY\"."
else
    envsubst < "$HERE"/files/authelia.config.yaml >"$STATE_DIR"/authelia/config/configuration.yml
fi

echo "$AUTHELIA_USERS_DATABASE" >"$STATE_DIR"/authelia/config/users_database.yml
if [ ! -f "$STATE_DIR"/traefik/acme.json ]; then
    echo '{}' >"$STATE_DIR"/traefik/acme.json
    echo "Created an empty \"acme.json\"."
fi
chmod 600 "$STATE_DIR"/traefik/acme.json
envsubst < "$HERE"/files/traefik.dynamic-configuration.yaml > "$STATE_DIR"/traefik/dynamic-configuration.yaml

echo "Done."

printTitle "Generate Docker Compose file"
envsubst < "$HERE"/compose.yaml > "$STATE_DIR"/compose.yaml
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
