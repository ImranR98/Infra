# ====== Domain ======
export SERVICES_DOMAIN="staging.example.org"
export DOMAIN_OWNER_EMAIL="contact@$SERVICES_DOMAIN"

# ====== Owncast viewer access ======
export OWNCAST_ACCESS_TOKEN="change_me" # openssl rand -hex 32

# ====== FRP ======
export PROXY_HOST="change_me" # hostname of the FRP server (e.g. vps1.example.org)
# Generate with: ./infra.sh pc0 compose generate-frp-certs vps1
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
