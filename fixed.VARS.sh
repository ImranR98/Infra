#!/bin/bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

export MY_UID="$UID" # For some reason, using $UID directly in yaml files (via envsubst) causes errors but this weirdly fixes it
export MAIN_NODE_HOSTNAME_LOWERCASE="${MAIN_NODE_HOSTNAME,,}"
export PROXY_NODE_HOSTNAME_LOWERCASE="${PROXY_NODE_HOSTNAME,,}"
export HELPERS_PATH="$HERE/helpers.sh"

export TRAEFIK_TRUSTED_IP_RANGE="$(ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1' | tail -1)"

export SERVICES_TLS_NAME="$(echo "$SERVICES_TOP_DOMAIN" | sed 's/\./-/g')"

export PROXY_SSH_STRING="$PROXY_USER"@"$PROXY_HOST"
export PROXY_HOME="/home/$PROXY_USER"
if [ "$PROXY_USER" = root ]; then
    export PROXY_HOME="/root"
fi