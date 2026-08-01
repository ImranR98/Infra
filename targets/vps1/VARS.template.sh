# ====== Domain ======
export SERVICES_DOMAIN="staging.example.org"
export DOMAIN_OWNER_EMAIL="contact@example.org"

# ====== FRP ======
# Generate with: ./infra.sh pc0 compose generate-frp-certs vps1
# Use the heredoc pattern below for multi-line PEM data:
export FRP_CA_CERT="$(cat <<'FRP_CERT_EOF'
-----BEGIN CERTIFICATE-----
<CA-certificate-pem-block>
-----END CERTIFICATE-----
FRP_CERT_EOF
)"
export FRP_SERVER_CERT="$(cat <<'FRP_CERT_EOF'
-----BEGIN CERTIFICATE-----
<server-certificate-pem-block>
-----END CERTIFICATE-----
FRP_CERT_EOF
)"
export FRP_SERVER_KEY="$(cat <<'FRP_CERT_EOF'
-----BEGIN PRIVATE KEY-----
<server-private-key-pem-block>
-----END PRIVATE KEY-----
FRP_CERT_EOF
)"
