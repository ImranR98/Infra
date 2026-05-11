#!/bin/bash
set -e

HERE_LX1A="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE_LX1A"/prep_env.sh

printTitle "Create Required Directories"
grep -Eo '\$MAIN_PARENT_DIR[^:]+:' "$HERE_LX1A"/landscape.docker-compose.yaml | awk -F: '{print $1}' | grep -E '/[^(/|.)]+$' | while read dir; do
    mkdir -p "$MAIN_PARENT_DIR/$(echo $dir | tail -c +18)" 2>/dev/null || :
done
grep -Eo '\$STATE_DIR[^:]+:' "$HERE_LX1A"/landscape.docker-compose.yaml | awk -F: '{print $1}' | grep -E '/[^(/|.)]+$' | while read dir; do
    mkdir -p "$STATE_DIR/$(echo $dir | tail -c +12)" 2>/dev/null || :
done
mkdir -p "$STATE_DIR"/logtfy
mkdir -p "$STATE_DIR"/traefik_logs
echo "Done."

printTitle "Re/generate various state files"
IGNORE_AUTHELIA_IGNORED_LINES=true
if [ -f "$STATE_DIR/authelia/config/configuration.yml" ]; then
    read -p 'Should the "ignored" lines in the Authelia config still be ignored? [y]: ' IGNORE_AUTHELIA_IGNORED_LINES_RESPONSE
    if [ "$IGNORE_AUTHELIA_IGNORED_LINES_RESPONSE" == 'n' ] || [ "$IGNORE_AUTHELIA_IGNORED_LINES_RESPONSE" == 'N' ]; then
        IGNORE_AUTHELIA_IGNORED_LINES=false
    fi
fi
if [ "$IGNORE_AUTHELIA_IGNORED_LINES" == true ]; then
    sed '/# IGNORE INITIALLY$/ s/^/# /' "$HERE_LX1A"/files/authelia.config.yaml | envsubst >"$STATE_DIR"/authelia/config/configuration.yml
    echo "Note that the generated Authelia config does not include lines that end with \"# IGNORE INITIALLY\"."
else
    cat "$HERE_LX1A"/files/authelia.config.yaml | envsubst >"$STATE_DIR"/authelia/config/configuration.yml
fi

echo "$AUTHELIA_USERS_DATABASE" >"$STATE_DIR"/authelia/config/users_database.yml
if [ ! -f "$STATE_DIR"/traefik/acme.json ]; then
    echo '{}' >"$STATE_DIR"/traefik/acme.json
    echo "Created an empty \"acme.json\"."
fi
chmod 600 "$STATE_DIR"/traefik/acme.json
cat "$HERE_LX1A"/files/traefik.dynamic-configuration.yaml | envsubst >"$STATE_DIR"/traefik/dynamic-configuration.yaml
cat "$HERE_LX1A"/files/logtfy.json | envsubst >"$STATE_DIR"/logtfy/config.json
echo "Done."

printTitle "Generate Docker Compose file"
cat "$HERE_LX1A"/landscape.docker-compose.yaml | envsubst >"$STATE_DIR"/landscape.docker-compose.yaml
echo "Done."

printTitle "Install and start the Landscape service"
generateComposeService landscape 1000 >"$STATE_DIR"/landscape.service
awk -v SCRIPT_DIR="$STATE_DIR" '{gsub("path_to_here", SCRIPT_DIR); print}' "$STATE_DIR"/landscape.service >"$STATE_DIR"/landscape.service.temp
awk -v MY_UID="$(id -u)" '{gsub("1000", MY_UID); print}' "$STATE_DIR"/landscape.service.temp >"$STATE_DIR"/landscape.service
rm "$STATE_DIR"/landscape.service.temp
$SUDO_COMMAND bash -c "mv "$STATE_DIR"/landscape.service /etc/systemd/system/landscape.service && \
    chcon -t systemd_unit_file_t /etc/systemd/system/landscape.service && \
    systemctl daemon-reload && systemctl enable landscape.service && \
    (systemctl stop landscape.service || :) && sleep 5 && systemctl start landscape.service"
echo "Done."

printTitle "Finished"
echo "Note:
- Some services may need manual setup in their respective GUIs."
printLine -
