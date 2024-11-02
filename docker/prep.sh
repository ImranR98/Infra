#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE"/../helpers.sh # TODO: The '../' here and in the next few lines will need to be removed after the files are moved
if [ -f "$HERE"/../VARS.production.sh ]; then
    source "$HERE"/../VARS.production.sh
elif [ -f "$HERE"/../VARS.staging.sh ]; then
    source "$HERE"/../VARS.staging.sh
elif [ -f "$HERE"/../VARS.sh ]; then
    source "$HERE"/../VARS.sh
else
    echo "No VARS.sh file found!" >&2
    exit 1
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)" # TODO: Not needed after file is moved to root
source "$HERE"/../fixed.VARS.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)" # TODO: Not needed after file is moved to root

echo $STATE_DIR
STATE_DIR="${STATE_DIR}_docker" # TODO: Temporary

# Ensure state dirs exist
for dir in $(grep -Eo '\$STATE_DIR[^:]+:' "$HERE"/docker-compose.yaml | awk -F: '{print $1}' | grep -E '/[^(/|.)]+$'); do
    mkdir -p "$STATE_DIR/$(echo $dir | tail -c +12)"
done


# $STATE_DIR/logtfy/config.json
# $STATE_DIR/authelia/config/configuration.yaml
# $STATE_DIR/authelia/config/users_database.yaml
# $STATE_DIR/traefik/acme.json
# $STATE_DIR/traefik/dynamic-configuration.yaml
# $STATE_DIR/traefik/mtls/cacert.pem
# $STATE_DIR/traefik/mtls/cakey.pem
# $STATE_DIR/prometheus/prometheus.yaml
# $STATE_DIR/crowdsec/acquis.yaml
# $STATE_DIR/crowdsec/profiles.yaml
# $STATE_DIR/crowdsec/notifications-http.yaml
# $STATE_DIR/opencanary/opencanary.json
# $STATE_DIR/filebrowser/filebrowser.db
# $STATE_DIR/filebrowser/filebrowser.json
# $STATE_DIR/ntfy/etc/server.yml
# $STATE_DIR/mosquitto/config/mosquitto.conf