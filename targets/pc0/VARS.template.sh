# --- Domain ---
export SERVICES_DOMAIN="staging.example.org"
export DOMAIN_OWNER_EMAIL="contact@$SERVICES_DOMAIN"

# --- FRP ---
export PROXY_HOST="change_me" # e.g. vps1.example.org
# Generate with: ./atlas.sh pc0 compose generate-frp-certs vps1
export FRP_CA_CERT="change_me" # PEM-encoded CA certificate for this FRP pair
export FRP_CA_KEY="change_me" # PEM-encoded CA private key (keep on operator machine)
export FRP_CLIENT_CERT="change_me" # PEM-encoded client certificate
export FRP_CLIENT_KEY="change_me" # PEM-encoded client private key

# --- Owncast viewer access ---
export OWNCAST_ACCESS_TOKEN="change_me" # openssl rand -hex 32