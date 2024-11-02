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

# Generate required config files
cat "$HERE"/config-templates/logtfy.json | envsubst >"$STATE_DIR"/logtfy/config.json
cat "$HERE"/config-templates/authelia.config.yaml | envsubst >"$STATE_DIR"/authelia/config/configuration.yaml
echo "$$AUTHELIA_USERS_DATABASE" >"$STATE_DIR"/authelia/config/users_database.yaml
if [ ! -f "$STATE_DIR"/traefik/acme.json ]; then
    echo '[]' >"$STATE_DIR"/traefik/acme.json
fi
cat "$HERE"/config-templates/traefik.dynamic-configuration.yaml | envsubst >"$STATE_DIR"/traefik/dynamic-configuration.yaml
cat "$HERE"/config-templates/prometheus.yaml | envsubst >"$STATE_DIR"/prometheus/prometheus.yaml
cat "$HERE"/config-templates/crowdsec.acquis.yaml | envsubst >"$STATE_DIR"/crowdsec/acquis.yaml
cat "$HERE"/config-templates/crowdsec.notifications-http.yaml | envsubst >"$STATE_DIR"/crowdsec/notifications-http.yaml
cat "$HERE"/config-templates/crowdsec.profiles.yaml | envsubst >"$STATE_DIR"/crowdsec/profiles.yaml
cat "$HERE"/config-templates/opencanary.json | envsubst >"$STATE_DIR"/opencanary/opencanary.json
touch "$STATE_DIR"/filebrowser/filebrowser.db
cat "$HERE"/config-templates/filebrowser.json | envsubst >"$STATE_DIR"/filebrowser/filebrowser.json
cat "$HERE"/config-templates/ntfy.server.yml | envsubst >"$STATE_DIR"/ntfy/server.yml
cat "$HERE"/config-templates/mosquitto.conf | envsubst >"$STATE_DIR"/mosquitto/config/mosquitto.conf
echo "$MOSQUITTO_PRIVATE_KEY" >"$STATE_DIR"/mosquitto/config/private_key.pem
echo "$MOSQUITTO_CERTIFICATE" >"$STATE_DIR"/mosquitto/config/certificate.pem
echo "$MOSQUITTO_CREDENTIALS" >"$STATE_DIR"/mosquitto/config/password_file
if [ ! -f "$STATE_DIR"/traefik/mtls/cacert.pem ] || [ ! -f "$STATE_DIR"/traefik/mtls/cakey.pem ]; then
    openssl genrsa -out "$STATE_DIR"/traefik/mtls/cakey.pem 4096
    openssl req -new -x509 -key "$STATE_DIR"/traefik/mtls/cakey.pem -out "$STATE_DIR"/traefik/mtls/cacert.pem
fi
