# ====== Domain ======
export SERVICES_DOMAIN="home.example.org"
export DOMAIN_OWNER_EMAIL="contact@example.org"
export TZ="America/Toronto"

# ====== Ntfy ======
export NTFY_WRITE_ONLY_ACCOUNT_TOKEN="change_me" # "tk_$(openssl rand -hex 16)"
export NTFY_FALLBACK_TOPIC="change_me" # openssl rand -hex 16
export NTFY_ADMIN_PASSWORD_HASH="change_me" # docker run --rm -it binwiederhier/ntfy user hash
export NTFY_WRITE_ONLY_ACCOUNT_PASSWORD_HASH="change_me" # docker run --rm -it binwiederhier/ntfy user hash

# ====== Geoblock (Traefik middleware) ======
# Indentation matters — must match spec.plugin.geoblock level in middlewares.yaml (6 spaces).
export GEOBLOCK_CONFIG_SUBSET='
      blackListMode: false
      countries:
        - CA
        - CN
        - CU
'

# ====== GeoIP (self-hosted MaxMind GeoLite2) ======
# Register at https://www.maxmind.com and generate a GeoLite2 license key
export GEOIPUPDATE_ACCOUNT_ID="change_me"
export GEOIPUPDATE_LICENSE_KEY="change_me"

# ====== Host Paths ======
# Ensure these exist before starting services
export MAIN_PARENT_DIR="/path/to/data"
export MEDIA_DIR_PATH="$MAIN_PARENT_DIR/Main/Media"
export DSCPLN_TRANSACTIONS_PATH="$MAIN_PARENT_DIR/Main/Notes/Transactions"
export MDSCL_DEVICE_SYNC_PATH="$MAIN_PARENT_DIR/deviceSync"
export SECONDARY_STORAGE_PATH="/mnt/k3s_extra_storage"

# ====== Authelia ======
# Use `docker run -it authelia/authelia:latest authelia crypto hash generate argon2` to generate the password hash
# Indentation matters: needs 2 spaces more than the 4-space block scalar base (6/8/10 spaces)
# For one-time 2FA registration: kubectl -n base exec -it "$(kubectl -n base get pod | grep -E '^authelia' | grep -Ev '(postgres|redis)' | awk '{print $1}')" -- cat /notifications/notification.txt
export AUTHELIA_USERS_DATABASE="users:
      admin:
        disabled: false
        displayname: \"Admin\"
        password: \"\$argon2id\$v=19\$m=65536,t=3,p=abc\"
        email: $DOMAIN_OWNER_EMAIL
        groups:
          - admins"
export AUTHELIA_DB_ENCRYPTION_KEY="change_me" # openssl rand -hex 128
export AUTHELIA_JWT_SECRET="change_me" # openssl rand -hex 128
export AUTHELIA_OIDC_HMAC_SECRET="change_me" # openssl rand -hex 128
export AUTHELIA_REDIS_PASSWORD="change_me" # openssl rand -base64 32
export AUTHELIA_DB_PASSWORD="change_me" # openssl rand -base64 32
# openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null | base64 | tr -d '\n'
# Indentation matters
export AUTHELIA_JWKS_KEY="-----BEGIN PRIVATE KEY-----
                  change_me
                  -----END PRIVATE KEY-----"
export AUTHELIA_IMMICH_CLIENT_SECRET_HASHABLE="change_me" # docker run authelia/authelia:latest authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986
export AUTHELIA_OPENWEBUI_CLIENT_SECRET_HASHABLE="change_me" # docker run authelia/authelia:latest authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986
export AUTHELIA_HEADLAMP_CLIENT_SECRET_HASHABLE="change_me" # docker run authelia/authelia:latest authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986

# ====== Crowdsec ======
export CROWDSEC_BOUNCER_KEY="change_me" # openssl rand -hex 32
export CROWDSEC_LAPI_SECRET="change_me" # openssl rand -hex 32

# ====== Localhost Basic Auth ======
export LOCALHOST_AUTH_USER="admin"
export LOCALHOST_AUTH_PASSWORD_HASH="change_me" # openssl passwd -6 'password'

# ====== Immich ======
export IMMICH_DB_PASSWORD="change_me" # openssl rand -hex 16

# ====== Mosquitto ======
# Format: mosquitto password file lines ("user:hash"), ONE LINE PER ENTRY, each line
# indented with 4 spaces (rendered into a YAML block scalar, like AUTHELIA_USERS_DATABASE).
# Add app users with: tmpfile=$(mktemp) && mosquitto_passwd -b "$tmpfile" frigate '<FRIGATE_MQTT_PASSWORD>' \
#   && mosquitto_passwd -b "$tmpfile" homeassistant '<HA_MQTT_PASSWORD>' && cat "$tmpfile"
export MOSQUITTO_CREDENTIALS="change_me" # tmpfile=$(mktemp) && mosquitto_passwd -b "$tmpfile" admin 'your-password' && cat "$tmpfile" && rm "$tmpfile"

# ====== Frigate (NVR) ======
# Host running the rpi go2rtc stream (targets/rpi)
export RPI_CAMERA_IP="192.168.8.XX"
# Password of the rpi go2rtc stream: `docker logs go2rtc` on the Pi, or
# current_target/compose_live_state/go2rtc/password. Update if the Pi password regenerates.
export FRIGATE_RTSP_PASSWORD="change_me"
export FRIGATE_MQTT_PASSWORD="change_me" # openssl rand -hex 16 (also add `frigate` user to MOSQUITTO_CREDENTIALS)
export HA_MQTT_PASSWORD="change_me" # openssl rand -hex 16 (also add `homeassistant` user to MOSQUITTO_CREDENTIALS)

# ====== FreshRSS ======
export FRESHRSS_PASSWORD="change_me" # openssl rand -base64 32

# ====== Plik ======
export PLIK_ADMIN_PASSWORD="change_me" # openssl rand -hex 16

# ====== D$CPLN ======
export DSCPLN_DATA_FILE="Acc $(date +%Y).md"
export DSCPLN_BUDGET_INIT_AMT="2400"
export DSCPLN_FIRST_WEEK_BIAS_INIT_AMT="1400"

# ====== FMD ======
export FMD_REGISTRATIONTOKEN="change_me" # openssl rand -base64 32

# ====== OpenCanary ======
export OPENCANARY_NTFY_SECRET_TOPIC="change_me" # openssl rand -base64 32

# ====== Radarr / Sonarr ======
export RADARR_API_KEY="change_me" # openssl rand -hex 16
export SONARR_API_KEY="change_me" # openssl rand -hex 16

# ====== Prowlarr ======
export PROWLARR_API_KEY="change_me" # openssl rand -hex 16

# ====== Nextcloud ======
export NEXTCLOUD_ADMIN_USER="admin"
export NEXTCLOUD_ADMIN_PASSWORD="change_me" # openssl rand -hex 16
export NEXTCLOUD_DB_PASSWORD="change_me" # openssl rand -hex 16

# ====== Copyparty ======
export COPYPARTY_ADMIN_PASSWORD="changeme" # openssl rand -hex 16

# ====== FRP ======
export PROXY_HOST="vps0.example.org"
# Generate with: ./infra.sh srv0 compose generate-frp-certs vps0
# Use the heredoc pattern below for multi-line PEM data:
export FRP_CA_CERT="$(cat <<'FRP_CERT_EOF'
-----BEGIN CERTIFICATE-----
<CA-certificate-pem-block>
-----END CERTIFICATE-----
FRP_CERT_EOF
)"
export FRP_CA_KEY="$(cat <<'FRP_CERT_EOF'
-----BEGIN PRIVATE KEY-----
<CA-private-key-pem-block>
-----END PRIVATE KEY-----
FRP_CERT_EOF
)"
export FRP_CLIENT_CERT="$(cat <<'FRP_CERT_EOF'
-----BEGIN CERTIFICATE-----
<client-certificate-pem-block>
-----END CERTIFICATE-----
FRP_CERT_EOF
)"
export FRP_CLIENT_KEY="$(cat <<'FRP_CERT_EOF'
-----BEGIN PRIVATE KEY-----
<client-private-key-pem-block>
-----END PRIVATE KEY-----
FRP_CERT_EOF
)"
export FRP_PREBOOT_CLIENT_CERT="$(cat <<'FRP_CERT_EOF'
-----BEGIN CERTIFICATE-----
<preboot-client-certificate-pem-block>
-----END CERTIFICATE-----
FRP_CERT_EOF
)"
export FRP_PREBOOT_CLIENT_KEY="$(cat <<'FRP_CERT_EOF'
-----BEGIN PRIVATE KEY-----
<preboot-client-private-key-pem-block>
-----END PRIVATE KEY-----
FRP_CERT_EOF
)"
