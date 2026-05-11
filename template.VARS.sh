#!/bin/bash

# NOTE: Indentation must be retained in multiline variables

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# --- Node / Server Identity ---
# Hostname of the main server node
export MAIN_NODE_HOSTNAME="controlplane"

# Directory for auto-generated persistent state (Docker volume bind targets, config, DBs)
export STATE_DIR="$HERE/state"

# Parent directory for user-facing app data (documents, uploads, etc.)
export MAIN_PARENT_DIR="$HERE/mock-data"

# --- Domains ---
# The subdomain under which all services are hosted (e.g. "services.example.org")
export SERVICES_DOMAIN="staging.example.org"

# Email for Let's Encrypt certificate registration
export DOMAIN_OWNER_EMAIL="contact@example.org"

# --- Notifications ---
# Auth token for the ntfy service user that Luna services use to push notifications
export NTFY_SERVICE_USER_TOKEN=""

# --- Authelia ---
# YAML string defining the Authelia users database (users, passwords, groups)
# Use `authelia hash-password` to generate the Argon2id hash
export AUTHELIA_USERS_DATABASE="users:
  admin:
    disabled: false
    displayname: \"Admin\"
    password: \"\$argon2id\$v=19\$m=65536,t=3,p=abc\"
    email: $DOMAIN_OWNER_EMAIL
    groups:
      - admins"

# Authelia secrets (generate unique random values for each)
export AUTHELIA_DB_ENCRYPTION_KEY="abc"
export AUTHELIA_SESSION_SECRET="abc"
export AUTHELIA_JWT_SECRET="abc"
export AUTHELIA_OIDC_HMAC_SECRET="abc"
export AUTHELIA_JWKS_KEY="-----BEGIN PRIVATE KEY-----
          abc
          -----END PRIVATE KEY-----"

# --- Plausible Analytics ---
# Generate with: openssl rand -base64 64 | tr -d '\n'
export PLAUSIBLE_SECRET_KEY="abc"
export PLAUSIBLE_TOTP_VAULT_KEY="abc"
# Password for the Plausible PostgreSQL database
export PLAUSIBLE_DB_PASSWORD="change_me"

# --- PixelNtfy ---
# Suffix appended to the PixelNtfy ntfy topic for uniqueness
export PIXELNTFY_TOPIC_SUFFIX='abc'

# --- SB25 Birthday Page ---
# Auth token for the sb25 service (generate a random hex string)
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
