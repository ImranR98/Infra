#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HELPERS_PATH"
helm repo update
helm upgrade --install --namespace production immich immich/immich --values <(cat "$HERE"/values.yaml | envsubst)

printLine -
echo "NOTE: Modify settings in the GUI to enable OAuth. Enter these values:
    issuerUrl: https://auth.$SERVICES_DOMAIN/.well-known/openid-configuration
    clientId: immich
    clientSecret: $IMMICH_OAUTH_CLIENT_SECRET
    autoLaunch: true
NOTE: External libraries are mounted under '/external'."
