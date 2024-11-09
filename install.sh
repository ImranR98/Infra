#!/bin/bash
set -e

HERE_LX1A="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE_LX1A"/prep_env.sh

printTitle "Install Docker"
if [ -z "$(docker compose version 2>/dev/null || :)" ]; then
    sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo --overwrite &&
        sudo dnf -q install docker-ce docker-compose-plugin -y &&
        sudo systemctl enable --now -q docker && sleep 5 &&
        sudo systemctl is-active docker &&
        sudo usermod -aG docker $USER
else
    echo "Already installed."
fi

printTitle "Create Required Directories"
grep -Eo '\$MAIN_PARENT_DIR[^:]+:' "$HERE_LX1A"/landscape.docker-compose.yaml | awk -F: '{print $1}' | grep -E '/[^(/|.)]+$' | while read dir; do
    mkdir -p "$MAIN_PARENT_DIR/$(echo $dir | tail -c +18)"
done
grep -Eo '\$STATE_DIR[^:]+:' "$HERE_LX1A"/landscape.docker-compose.yaml | awk -F: '{print $1}' | grep -E '/[^(/|.)]+$' | while read dir; do
    mkdir -p "$STATE_DIR/$(echo $dir | tail -c +12)"
done
mkdir -p "$STATE_DIR"/logtfy
mkdir -p "$STATE_DIR"/prometheus
mkdir -p "$STATE_DIR"/opencanary
mkdir -p "$STATE_DIR"/filebrowser
mkdir -p "$STATE_DIR"/plausible
mkdir -p "$STATE_DIR"/frpc
echo "Done."

printTitle "Generate Required Config Files"
cat "$HERE_LX1A"/files/logtfy.json | envsubst >"$STATE_DIR"/logtfy/config.json
if [ ! -f ""$STATE_DIR"/authelia/config/configuration.yml" ]; then
    sed '/# IGNORE INITIALLY$/ s/^/# /' "$HERE_LX1A"/files/authelia.config.yaml | envsubst >"$STATE_DIR"/authelia/config/configuration.yml
    echo "- Generated Authelia config does not include lines that end with \"# IGNORE INITIALLY\"."
else
    cat "$HERE_LX1A"/files/authelia.config.yaml | envsubst >"$STATE_DIR"/authelia/config/configuration.yml
fi
echo "$AUTHELIA_USERS_DATABASE" >"$STATE_DIR"/authelia/config/users_database.yml
if [ ! -f "$STATE_DIR"/traefik/acme.json ]; then
    echo '{}' >"$STATE_DIR"/traefik/acme.json
    echo "- Empty \"acme.json\" created."
fi
chmod 600 "$STATE_DIR"/traefik/acme.json
cat "$HERE_LX1A"/files/traefik.dynamic-configuration.yaml | envsubst >"$STATE_DIR"/traefik/dynamic-configuration.yaml
cat "$HERE_LX1A"/files/prometheus.yaml | envsubst >"$STATE_DIR"/prometheus/prometheus.yaml
cat "$HERE_LX1A"/files/crowdsec.acquis.yaml | envsubst >"$STATE_DIR"/crowdsec/acquis.yaml
cat "$HERE_LX1A"/files/crowdsec.notifications-http.yaml | envsubst >"$STATE_DIR"/crowdsec/notifications-http.yaml
cat "$HERE_LX1A"/files/crowdsec.profiles.yaml | envsubst >"$STATE_DIR"/crowdsec/profiles.yaml
cat "$HERE_LX1A"/files/opencanary.json | envsubst >"$STATE_DIR"/opencanary/opencanary.json
if [ ! -f "$STATE_DIR"/filebrowser/filebrowser.db ]; then
    touch "$STATE_DIR"/filebrowser/filebrowser.db
    echo "- New \"filebrowser.db\" created."
fi
cat "$HERE_LX1A"/files/filebrowser.json | envsubst >"$STATE_DIR"/filebrowser/filebrowser.json
cat "$HERE_LX1A"/files/ntfy.server.yml | envsubst >"$STATE_DIR"/ntfy/etc/server.yml
cp "$HERE_LX1A"/files/immich.hwaccel.ml.yml "$STATE_DIR"/immich/hwaccel.ml.yml
cp "$HERE_LX1A"/files/immich.hwaccel.transcoding.yml "$STATE_DIR"/immich/hwaccel.transcoding.yml
cp "$HERE_LX1A"/files/plausible.logs.xml "$STATE_DIR"/plausible/logs.xml
cp "$HERE_LX1A"/files/plausible.ipv4-only.xml "$STATE_DIR"/plausible/ipv4-only.xml
cat "$HERE_LX1A"/files/mosquitto.conf | envsubst | sudo dd status=none of="$STATE_DIR"/mosquitto/config/mosquitto.conf
echo "$MOSQUITTO_PRIVATE_KEY" | sudo dd status=none of="$STATE_DIR"/mosquitto/config/private_key.pem
echo "$MOSQUITTO_CERTIFICATE" | sudo dd status=none of="$STATE_DIR"/mosquitto/config/certificate.pem
echo "$MOSQUITTO_CREDENTIALS" | sudo dd status=none of="$STATE_DIR"/mosquitto/config/password_file
echo "$WEBDAV_HTPASSWD" >"$STATE_DIR"/webdav/config/htpasswd
if [ ! -f "$STATE_DIR"/traefik/mtls/cacert.pem ] || [ ! -f "$STATE_DIR"/traefik/mtls/cakey.pem ]; then
    openssl genrsa -out "$STATE_DIR"/traefik/mtls/cakey.pem 4096
    openssl req -new -x509 -key "$STATE_DIR"/traefik/mtls/cakey.pem -out "$STATE_DIR"/traefik/mtls/cacert.pem -subj "/CN=$SERVICES_DOMAIN"
    echo "Generating mTLS client cert file..."
    openssl pkcs12 -export -out "$STATE_DIR"/traefik/mtls/mtls-client.p12 -inkey "$STATE_DIR"/traefik/mtls/cakey.pem -in "$STATE_DIR"/traefik/mtls/cacert.pem
    echo "- New mTLS key + cert created."
fi
bash "$HERE_LX1A"/files/frpc.generate.sh
mv "$HERE_LX1A"/files/frpc.ini "$STATE_DIR"/frpc
if [ ! -d "$STATE_DIR"/crowdsec/dashboard-db/metabase.db ]; then
    wget -q https://crowdsec-statics-assets.s3-eu-west-1.amazonaws.com/metabase_sqlite.zip -O "$STATE_DIR"/crowdsec/dashboard-db/metabase.db.zip
    unzip -q "$STATE_DIR"/crowdsec/dashboard-db/metabase.db.zip -d "$STATE_DIR"/crowdsec/dashboard-db/
    rm "$STATE_DIR"/crowdsec/dashboard-db/metabase.db.zip
    echo "- Crowdsec dashboard initialized with email \"crowdsec@crowdsec.net\" and password \"!!Cr0wdS3c_M3t4b4s3??\""
fi
if [ ! -f "$STATE_DIR"/immich/oauth_info.txt ]; then
    PRINT_IMMICH_OAUTH_INFO=true
fi
echo "    - issuerUrl: https://auth.$SERVICES_DOMAIN/.well-known/openid-configuration
    - clientId: immich
    - clientSecret: $IMMICH_OAUTH_CLIENT_SECRET
    - autoLaunch: true" >"$STATE_DIR"/immich/oauth_info.txt
if [ -n "$PRINT_IMMICH_OAUTH_INFO" ]; then
    echo "- Immich OAuth info for reference (must be set manually in the GUI):"
    cat "$STATE_DIR"/immich/oauth_info.txt
fi
sudo chown -R root:root "$STATE_DIR"/homeassistant
echo "Done."

printTitle "Generate Docker Compose File"
cat "$HERE_LX1A"/landscape.docker-compose.yaml | envsubst >"$STATE_DIR"/landscape.docker-compose.yaml
echo "Done."

if [ ! -f "$STATE_DIR"/homeassistant/configuration.yaml ] || [ -z "$(grep -Eo '^http' "$STATE_DIR"/homeassistant/configuration.yaml)" ]; then
    printTitle "Modify Auto-Generated Configuration for Home Assistant"
    docker compose -p landscape -f "$STATE_DIR"/landscape.docker-compose.yaml up -d homeassistant
    echo "Waiting for HA config file to be generated..."
    while [ ! -f "$STATE_DIR"/homeassistant/configuration.yaml ]; do
        sleep 1
    done
    cat "$HERE_LX1A"/files/homeassistant.config.http.yaml | sudo dd status=none of="$STATE_DIR"/homeassistant/configuration.yaml oflag=append conv=notrunc
    docker compose -p landscape -f "$STATE_DIR"/landscape.docker-compose.yaml down homeassistant
    echo "Done."
fi

if [ -z "$CROWDSEC_BOUNCER_KEY" ]; then
    printTitle "Generate Crowdsec Bouncer Key"
    docker compose -p landscape -f "$STATE_DIR"/landscape.docker-compose.yaml up -d crowdsec
    echo "Waiting for Crowdsec to start..."
    sleep 10 # Hopefully enough time for any initialization to occur
    docker exec crowdsec cscli bouncers remove crowdsecBouncer 2>/dev/null || :
    export CROWDSEC_BOUNCER_KEY="$(docker exec crowdsec cscli bouncers add crowdsecBouncer | head -3 | tail -1 | awk '{print $1}')"
    echo "export CROWDSEC_BOUNCER_KEY='$CROWDSEC_BOUNCER_KEY'" >>"$STATE_DIR"/generated.VARS.sh
    docker compose -p landscape -f "$STATE_DIR"/landscape.docker-compose.yaml down crowdsec
    echo "Done."
fi

if [ -z "$NTFY_SERVICE_USER_TOKEN" ]; then
    printTitle "Create Write-Only Ntfy Service Account + Token and Ntfy Admin Account"
    docker compose -p landscape -f "$STATE_DIR"/landscape.docker-compose.yaml up -d ntfy
    echo "Waiting for Ntfy to start..."
    sleep 10 # Hopefully enough time for any initialization to occur
    SERVICES_USER="${MAIN_NODE_HOSTNAME_LOWERCASE}_services"
    SERVICES_TOPIC="${SERVICES_USER}_*"
    docker exec ntfy ntfy user del "$SERVICES_USER" 2>/dev/null || :
    docker exec ntfy sh -c "NTFY_PASSWORD=\"$NTFY_SERVICES_PASSWORD\" ntfy user add \"$SERVICES_USER\""
    docker exec ntfy ntfy access "$SERVICES_USER" "$SERVICES_TOPIC" wo
    docker exec ntfy ntfy access "$SERVICES_USER" "$PIXELNTFY_TOPIC_SUFFIX" wo
    export NTFY_SERVICE_USER_TOKEN="$(docker exec ntfy ntfy token add "$SERVICES_USER" 2>&1 | awk '{print $2}')"
    echo "export NTFY_SERVICE_USER_TOKEN='$NTFY_SERVICE_USER_TOKEN'" >>"$STATE_DIR"/generated.VARS.sh
    read -s -p "Enter password for Ntfy admin user: " NTFY_ADMIN_PASSWORD
    docker exec ntfy ntfy user del "$USER" 2>/dev/null || :
    docker exec ntfy sh -c "NTFY_PASSWORD=\"$NTFY_ADMIN_PASSWORD\" ntfy user add \"$USER\""
    docker exec ntfy sh -c "ntfy access $USER \"*\" rw"
    docker exec ntfy sh -c "ntfy user change-role $USER admin"
    docker compose -p landscape -f "$STATE_DIR"/landscape.docker-compose.yaml down ntfy
    echo "Done."
fi

printTitle "Regenerate Docker Compose File to Pick Up any Changes"
cat "$HERE_LX1A"/landscape.docker-compose.yaml | envsubst >"$STATE_DIR"/landscape.docker-compose.yaml
echo "Done."

printTitle "Generate and Start the Systemd Service"
generateComposeService landscape 1000 >"$STATE_DIR"/landscape.service
awk -v SCRIPT_DIR="$STATE_DIR" '{gsub("path_to_here", SCRIPT_DIR); print}' "$STATE_DIR"/landscape.service >"$STATE_DIR"/landscape.service.temp
awk -v MY_UID="$(id -u)" '{gsub("1000", MY_UID); print}' "$STATE_DIR"/landscape.service.temp >"$STATE_DIR"/landscape.service
rm "$STATE_DIR"/landscape.service.temp
sudo mv "$STATE_DIR"/landscape.service /etc/systemd/system/landscape.service
sudo chcon -t systemd_unit_file_t /etc/systemd/system/landscape.service # Without this, SELinux prevents Systemd from seeing the file
sudo systemctl daemon-reload
sudo systemctl enable landscape.service
sudo systemctl stop landscape.service || :
sleep 5
sudo systemctl start landscape.service
echo "Done."

printTitle "Generate Docker Compose and Systemd Files for FRPC and Start the Service"
cat "$HERE_LX1A"/frpc.docker-compose.yaml | envsubst >"$STATE_DIR"/frpc.docker-compose.yaml

generateComposeService frpc 1000 >"$STATE_DIR"/frpc.service
awk -v SCRIPT_DIR="$STATE_DIR" '{gsub("path_to_here", SCRIPT_DIR); print}' "$STATE_DIR"/frpc.service >"$STATE_DIR"/frpc.service.temp
awk -v MY_UID="$(id -u)" '{gsub("1000", MY_UID); print}' "$STATE_DIR"/frpc.service.temp >"$STATE_DIR"/frpc.service
rm "$STATE_DIR"/frpc.service.temp
sudo mv "$STATE_DIR"/frpc.service /etc/systemd/system/frpc.service
sudo chcon -t systemd_unit_file_t /etc/systemd/system/frpc.service
sudo systemctl daemon-reload
sudo systemctl enable frpc.service
sudo systemctl start frpc.service
echo "Note: FRPC will not be automatically restarted due to the risk of failing to reconnect. You must restart it manually."
echo "Done."

printTitle "Finished"
echo "Note:
- You may still need to run install_remote.sh.
- Some image tags are hardcoded - you may need to update these manually.
- Some services may need manual setup in their respective GUIs."
printLine -