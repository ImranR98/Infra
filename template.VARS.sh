#!/bin/bash

# NOTE: Indentation must be retained in multiline variables

# Directory for auto-generated persistent state (Docker volume bind targets, config, DBs)
export STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/state"

# --- Domains ---
# The subdomain under which all services are hosted (e.g. "services.example.org")
export SERVICES_DOMAIN="staging.example.org"

# Email for Let's Encrypt certificate registration
export DOMAIN_OWNER_EMAIL="contact@example.org"

# --- Authelia ---
# YAML string defining the Authelia users database (users, passwords, groups)
# Use `docker run -it authelia/authelia:latest authelia crypto hash generate argon2` to generate the Argon2id hash
export AUTHELIA_USERS_DATABASE="users:
  admin:
    disabled: false
    displayname: \"Admin\"
    password: \"\$argon2id\$v=19\$m=65536,t=3,p=abc\"
    email: $DOMAIN_OWNER_EMAIL
    groups:
      - admins"

# Authelia secrets (generate unique random values for each using `openssl rand -base64 48`)
export AUTHELIA_DB_ENCRYPTION_KEY="abc"
export AUTHELIA_SESSION_SECRET="abc"
export AUTHELIA_JWT_SECRET="abc"
export AUTHELIA_OIDC_HMAC_SECRET="abc"
# openssl genrsa -out private.pem 2048; openssl rsa -in private.pem -outform PEM -pubout -out public.pem
export AUTHELIA_JWKS_KEY="-----BEGIN PRIVATE KEY-----
          abc
          -----END PRIVATE KEY-----"

# --- Plausible Analytics ---
export PLAUSIBLE_SECRET_KEY="abc" # openssl rand -base64 48
export PLAUSIBLE_TOTP_VAULT_KEY="abc" # openssl rand -base64 32

# --- PixelNtfy ---
# ntfy topic for PixelNtfy (should be long and unique)
export PIXELNTFY_TOPIC="abcd"

# --- SB25 Birthday Page ---
# Auth token for the sb25 service (generate a random string)
export SB25_AUTH_TOKEN="change_me"

# --- strelaysrv Relay Server ---
# The "provided-by" text displayed on the Syncthing relay server
export STRELAYSRV_PROVIDED_BY="$DOMAIN_OWNER_EMAIL"

# --- Geoblock (Traefik middleware) ---
# YAML subset for the geoblock plugin configuration (indentation matters)
export GEOBLOCK_CONFIG_SUBSET='
          blackListMode: false
          countries:
            - CA
            - CN
            - CU
'
