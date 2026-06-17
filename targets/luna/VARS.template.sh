# --- Domain ---
export SERVICES_DOMAIN="staging.example.org"
export DOMAIN_OWNER_EMAIL="contact@example.org"

# --- Logtfy ---
export NTFY_WRITE_ONLY_ACCOUNT_TOKEN="change_me" # "tk_$(openssl rand -hex 16)"
export NTFY_FALLBACK_TOPIC="change_me" # openssl rand -hex 16

# --- Geoblock (Traefik middleware) ---
# Indentation matters
export GEOBLOCK_CONFIG_SUBSET='
          blackListMode: false
          countries:
            - CA
            - CN
            - CU
'

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
export AUTHELIA_SESSION_SECRET="change_me" # openssl rand -hex 128
export AUTHELIA_JWT_SECRET="change_me" # openssl rand -hex 128

# --- Plausible Analytics ---
export PLAUSIBLE_SECRET_KEY="change_me" # openssl rand -base64 48
export PLAUSIBLE_TOTP_VAULT_KEY="change_me" # openssl rand -base64 32

# --- PixelNtfy ---
export PIXELNTFY_TOPIC="change_me" # openssl rand -hex 16

# --- SB25 Birthday Page ---
export SB25_AUTH_TOKEN="change_me" # openssl rand -hex 16

# --- strelaysrv Relay Server ---
export STRELAYSRV_PROVIDED_BY="$DOMAIN_OWNER_EMAIL"

# --- Shlink URL Shortener ---
export SHLINK_DB_PASSWORD="change_me" # openssl rand -hex 32
export SHLINK_API_KEY="change_me" # openssl rand -hex 32
export GEOLITE_LICENSE_KEY="" # (optional, see Shlink docs)

# --- FRP ---
export FRPC_TOKEN="change_me" # openssl rand -hex 128
export FRPC_PREBOOT_TOKEN="change_me" # openssl rand -hex 128
