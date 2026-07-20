# --- Domain ---
export SERVICES_DOMAIN="staging.example.org"
export DOMAIN_OWNER_EMAIL="contact@example.org"

# --- FRP ---
# Generate with: ./atlas.sh pc0 compose generate-frp-certs vps1
export FRP_CA_CERT="change_me" # PEM-encoded CA certificate for this FRP pair
export FRP_SERVER_CERT="change_me" # PEM-encoded server certificate
export FRP_SERVER_KEY="change_me" # PEM-encoded server private key