#!/bin/bash

# NOTE: Indentation must be retained in multiline variables

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

export MAIN_NODE_HOSTNAME="controlplane"
export PROXY_NODE_HOSTNAME="proxy"
export STATE_DIR="$HERE/state"
export MAIN_PARENT_DIR="$HERE/mock-data"

export SERVICES_DOMAIN="staging.example.org"
export SERVICES_TOP_DOMAIN="example.org"

export PROXY_USER="admin"
export PROXY_HOST="staging.example.org"

export DOMAIN_OWNER_EMAIL="contact@example.org"

export NTFY_SERVICES_PASSWORD="password"

export IMMICH_OAUTH_CLIENT_SECRET="abc" # echo $RANDOM | sha256sum | awk '{print $1}'
export IMMICH_DB_PASSWORD="abc"         # echo $RANDOM | sha256sum | awk '{print $1}'

export AUTHELIA_USERS_DATABASE="users:
  admin:
    disabled: false
    displayname: \"Admin\"
    password: \"\$argon2id\$v=19\$m=65536,t=3,p=abc\" # yamllint disable-line rule:line-length
    email: $DOMAIN_OWNER_EMAIL
    groups:
      - admins"                         # docker run -it authelia/authelia:latest authelia crypto hash generate argon2
export AUTHELIA_DB_ENCRYPTION_KEY="abc" # echo $RANDOM | sha256sum | awk '{print $1}'
export AUTHELIA_SESSION_SECRET="abc"    # echo $RANDOM | sha256sum | awk '{print $1}'
export AUTHELIA_JWT_SECRET="abc"        # echo $RANDOM | sha256sum | awk '{print $1}'
export AUTHELIA_OIDC_HMAC_SECRET="abc"  # echo $RANDOM | sha256sum | awk '{print $1}'
export AUTHELIA_JWKS_KEY="-----BEGIN PRIVATE KEY-----
          abc
          -----END PRIVATE KEY-----"                      #openssl genrsa -out private.pem 2048 # openssl rsa -in private.pem -outform PEM -pubout -out public.pem
export AUTHELIA_IMMICH_CLIENT_SECRET='$pbkdf2-sha512$abc' # docker run authelia/authelia:latest authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986 "$IMMICH_OAUTH_CLIENT_SECRET"

export OPENCANARY_NTFY_OFFICIAL_TOPIC="abc123"

export MONEROD_RPC_LOGIN="admin:abc"

export MOSQUITTO_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----
abc
-----END PRIVATE KEY-----" # openssl req  -nodes -new -x509  -keyout private_key.pem -out certificate.pem -subj "/C=CA/ST=Toronto/L=Toronto/O=$SERVICES_TOP_DOMAIN/OU=Main/CN=$SERVICES_TOP_DOMAIN"
export MOSQUITTO_CERTIFICATE="-----BEGIN CERTIFICATE-----
abc
-----END CERTIFICATE-----"
export MOSQUITTO_CREDENTIALS='admin:abc'

export PLAUSIBLE_SECRET_KEY="abc"     # openssl rand -base64 48
export PLAUSIBLE_TOTP_VAULT_KEY="abc" # openssl rand -base64 32

export STRELAYSRV_PROVIDED_BY_TEXT="example.org"

export WEBDAV_HTPASSWD='user:abc'   # touch htpasswd && htpasswd -B htpasswd user

export PIXELNTFY_TOPIC_SUFFIX='abc' # echo $RANDOM | sha256sum | awk '{print $1}' | head -c 32

export LOGTFY_SYNCTHING_EXCLUDED_DEVICE_IDS=''

export GEOBLOCK_CONFIG_SUBSET='
          blackListMode: false
          countries:
            - CA
            - CN
            - CU
'

export BESZEL_ENV_VARS='
            KEY: "ssh-ed25519 ABCXYZ"
            SENSORSS: "cros_ec_f75303_cpu,acpitz_2,nvme_sensor_2,cros_ec_peci,acpitz,coretemp_core_12,cros_ec_f75303_ddr,cros_ec_f75303_local,acpitz_1,coretemp_package_id_O,jc42,jc42_10,coretemp_core_4,coretemp_core_16,coretemp_core_17,coretemp_core_18,coretemp_core_19,coretemp_core_20,coretemp_core_21,coretemp_core_22,coretemp_core_23,nvme_composite,nyme_sensor_1,nvme_sensor_8,coretemp_core_8,coretemp_core_O,cros_ec_f75397-vccgt,acpitz_3,iwlwifi_1"'

export SHLINK_DB_PASSWORD="abc" # echo $RANDOM | sha256sum | awk '{print $1}'
export SHLINK_API_KEY="abc" # echo $RANDOM | sha256sum | awk '{print $1}'
export GEOLITE_LICENSE_KEY="" # Optional, see Shlink docs