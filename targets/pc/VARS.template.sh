# --- Domain ---
export SERVICES_DOMAIN="staging.example.org"
export DOMAIN_OWNER_EMAIL="contact@$SERVICES_DOMAIN"

# --- FRP ---
export PROXY_HOST="pcproxy.$SERVICES_DOMAIN"
export FRPC_TOKEN="change_me" # openssl rand -hex 128

# --- Owncast viewer access ---
export OWNCAST_ACCESS_TOKEN="change_me" # openssl rand -hex 32