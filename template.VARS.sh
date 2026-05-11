#!/bin/bash

# NOTE: Indentation must be retained in multiline variables

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

export MAIN_NODE_HOSTNAME="controlplane"
export STATE_DIR="$HERE/state"
export MAIN_PARENT_DIR="$HERE/mock-data"

export SERVICES_DOMAIN="staging.example.org"
export SERVICES_TOP_DOMAIN="example.org"

export DOMAIN_OWNER_EMAIL="contact@example.org"

export NTFY_SERVICE_USER_TOKEN=""

export AUTHELIA_USERS_DATABASE="users:
  admin:
    disabled: false
    displayname: \"Admin\"
    password: \"\$argon2id\$v=19\$m=65536,t=3,p=abc\"
    email: $DOMAIN_OWNER_EMAIL
    groups:
      - admins"
export AUTHELIA_DB_ENCRYPTION_KEY="abc"
export AUTHELIA_SESSION_SECRET="abc"
export AUTHELIA_JWT_SECRET="abc"
export AUTHELIA_OIDC_HMAC_SECRET="abc"
export AUTHELIA_JWKS_KEY="-----BEGIN PRIVATE KEY-----
          abc
          -----END PRIVATE KEY-----"

export PLAUSIBLE_SECRET_KEY="abc"
export PLAUSIBLE_TOTP_VAULT_KEY="abc"

export PIXELNTFY_TOPIC_SUFFIX='abc'

export GEOBLOCK_CONFIG_SUBSET='
          blackListMode: false
          countries:
            - CA
            - CN
            - CU
'
