# ====== Domain ======
# Base domain: services that stay on the original domain (public apps, FRP tunnel).
export BASE_SERVICES_DOMAIN="staging.example.org"
# Cloud tier domain: Authelia-protected services live here. Independent variable —
# set it explicitly in the secrets file (typically cloud.$BASE_SERVICES_DOMAIN).
export CLOUD_SERVICES_DOMAIN="cloud.$BASE_SERVICES_DOMAIN"
export DOMAIN_OWNER_EMAIL="contact@example.org"

# ====== Logtfy ======
export NTFY_WRITE_ONLY_ACCOUNT_TOKEN="change_me" # "tk_$(openssl rand -hex 16)"
export NTFY_FALLBACK_TOPIC="change_me" # openssl rand -hex 16

# ====== Geoblock (Traefik middleware) ======
# Indentation matters
export GEOBLOCK_CONFIG_SUBSET='
          blackListMode: false
          countries:
            - CA
            - CN
            - CU
'

# ====== Authelia ======
# Use `docker run -it authelia/authelia:latest authelia crypto hash generate argon2` to generate the password hash
# Indentation matters: compose writes this directly to a file, so use standard 2-space YAML nesting
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

# ====== Plausible Analytics ======
export PLAUSIBLE_SECRET_KEY="change_me" # openssl rand -base64 48
export PLAUSIBLE_TOTP_VAULT_KEY="change_me" # openssl rand -base64 32
export PLAUSIBLE_DB_PASSWORD="change_me" # openssl rand -hex 16

# ====== PixelNtfy ======
export PIXELNTFY_TOPIC="change_me" # openssl rand -hex 16

# ====== SB25 Birthday Page ======
export SB25_AUTH_TOKEN="change_me" # openssl rand -hex 16

# ====== CCT26 ======
export CCT26_REDDIT_COOKIE="change_me"  # Reddit session cookie
export CCT26_LLM_BASE_URL="change_me"   # LLM API base URL
export CCT26_LLM_MODEL="change_me"      # LLM model name
export CCT26_LLM_API_KEY="change_me"    # openssl rand -hex 32
export CCT26_NTFY_URL="change_me"       # ntfy topic URL for notifications
export CCT26_NTFY_AUTH="change_me"      # Authorization header value, e.g. "Bearer <ntfy token>"

# ====== strelaysrv Relay Server ======
export STRELAYSRV_PROVIDED_BY="$DOMAIN_OWNER_EMAIL"

# ====== Shlink URL Shortener ======
export SHLINK_DB_PASSWORD="change_me" # openssl rand -hex 32
export SHLINK_API_KEY="change_me" # openssl rand -hex 32
export GEOLITE_LICENSE_KEY="" # (optional, see Shlink docs)

# ====== Owncast ======
export OWNCAST_ACCESS_TOKEN="change_me"    # openssl rand -hex 32

# ====== FRP ======
# Generate with: ./infra.sh srv0 compose generate-mtls-certs vps0
# Use the heredoc pattern below for multi-line PEM data:
export MTLS_CA_CERT="$(cat <<'MTLS_CERT_EOF'
-----BEGIN CERTIFICATE-----
<CA-certificate-pem-block>
-----END CERTIFICATE-----
MTLS_CERT_EOF
)"
export MTLS_SERVER_CERT="$(cat <<'MTLS_CERT_EOF'
-----BEGIN CERTIFICATE-----
<server-certificate-pem-block>
-----END CERTIFICATE-----
MTLS_CERT_EOF
)"
export MTLS_SERVER_KEY="$(cat <<'MTLS_CERT_EOF'
-----BEGIN PRIVATE KEY-----
<server-private-key-pem-block>
-----END PRIVATE KEY-----
MTLS_CERT_EOF
)"
