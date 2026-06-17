# --- Domain ---
export SERVICES_DOMAIN="staging.example.org"
export DOMAIN_OWNER_EMAIL="contact@$SERVICES_DOMAIN"

# --- FRP ---
export PROXY_HOST="iris.$SERVICES_DOMAIN"
export FRPC_TOKEN="change_me" # openssl rand -hex 128
export FRPC_ADMIN_PASSWORD="change_me" # openssl rand -hex 16

# --- Owncast viewer access ---
export OWNCAST_ACCESS_TOKEN="change_me" # openssl rand -hex 32