#!/bin/bash
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE"/../../helpers.sh

SSH_USER=$USER
SSH_HOST=staging.example.org
SSH_STRING="$SSH_USER@$SSH_HOST"

NEW_RANDOM_TOKEN="$(echo $RANDOM | sha512sum | awk '{print $1}')$(echo $RANDOM | sha512sum | awk '{print $1}')"
syncRemoteEnvFileIfUndefined "$SSH_STRING" "/home/$SSH_USER/frps/frps-tokens.txt" "frontier" "$NEW_RANDOM_TOKEN" "$HERE"/temp_code.txt

TOKEN="$(grep -Eo '^frontier=.+' "$HERE"/temp_code.txt | tail -c +10)"
awk -v TOKEN="$TOKEN" '{gsub("put_token_here", TOKEN); print}' "$HERE"/frpc.template.ini | tee "$HERE"/../frpc.ini

if [ "$TOKEN" = "$NEW_RANDOM_TOKEN" ]; then
    echo "WARNING: A new token was generated (no existing token found on the FRPS server). This implies that FRPS has not been set up."
fi