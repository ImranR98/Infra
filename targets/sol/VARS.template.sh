# --- Domain ---
export SERVICES_DOMAIN="staging.example.org"
export DOMAIN_OWNER_EMAIL="contact@example.org"

# --- Ntfy ---
export NTFY_WRITE_ONLY_ACCOUNT_TOKEN="change_me" # "tk_$(openssl rand -hex 16)"
export NTFY_FALLBACK_TOPIC="change_me" # openssl rand -hex 16
export NTFY_ADMIN_PASSWORD_HASH="change_me" # docker run --rm -it binwiederhier/ntfy user hash
export NTFY_WRITE_ONLY_ACCOUNT_PASSWORD_HASH="change_me" # docker run --rm -it binwiederhier/ntfy user hash

# --- FRP ---
export PROXY_HOST="lens.$SERVICES_DOMAIN"
export FRPC_TOKEN="change_me" # openssl rand -hex 128
export FRPC_PREBOOT_TOKEN="change_me" # openssl rand -hex 128
export FRPC_ADMIN_PASSWORD="change_me" # openssl rand -hex 16

# --- Geoblock (Traefik middleware) ---
# Indentation matters
export GEOBLOCK_CONFIG_SUBSET='
          blackListMode: false
          countries:
            - CA
            - CN
            - CU
'

# --- Host Paths ---
# Ensure these exist before starting services
export MAIN_PARENT_DIR="/path/to/data"
export MEDIA_DIR_PATH="$MAIN_PARENT_DIR/Media"
export DSCPLN_TRANSACTIONS_PATH="$MAIN_PARENT_DIR/Documents/Balance"
export MDSCL_DEVICE_SYNC_PATH="$MAIN_PARENT_DIR/deviceSync"

# --- Authelia ---
# Use `docker run -it authelia/authelia:latest authelia crypto hash generate argon2` to generate the password hash
# Indentation matters
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
export AUTHELIA_IMMICH_CLIENT_SECRET="change_me" # docker run authelia/authelia:latest authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986
export AUTHELIA_OPENWEBUI_CLIENT_SECRET="change_me" # docker run authelia/authelia:latest authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986

# --- Crowdsec ---
export CROWDSEC_BOUNCER_KEY="change_me" # openssl rand -hex 32
export CROWDSEC_LAPI_SECRET="change_me" # openssl rand -hex 32

# --- Localhost Basic Auth ---
export LOCALHOST_AUTH_USER="admin"
export LOCALHOST_AUTH_PASSWORD_HASH="change_me" # openssl passwd -6 'password'

# --- Immich ---
export IMMICH_DB_PASSWORD="change_me" # openssl rand -hex 16

# --- Mosquitto ---
export MOSQUITTO_CREDENTIALS="change_me" # tmpfile=$(mktemp) && mosquitto_passwd -b "$tmpfile" admin 'your-password' && cat "$tmpfile" && rm "$tmpfile"

# --- FreshRSS ---
export FRESHRSS_PASSWORD="change_me" # openssl rand -base64 32

# --- D$CPLN ---
export DSCPLN_DATA_FILE="Acc $(date +%Y).md"
export DSCPLN_BUDGET_INIT_AMT="2400"
export DSCPLN_FIRST_WEEK_BIAS_INIT_AMT="1400"

# --- FMD ---
export FMD_REGISTRATION_TOKEN="change_me" # openssl rand -base64 32

# --- Nextcloud ---
export NEXTCLOUD_ADMIN_USER="admin"
export NEXTCLOUD_ADMIN_PASSWORD="change_me" # openssl rand -hex 16
export NEXTCLOUD_DB_PASSWORD="change_me" # openssl rand -hex 16
