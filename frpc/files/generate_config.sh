#!/bin/bash
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE"/../../helpers.sh

FRPC_USERNAME="$MAIN_NODE_HOSTNAME_LOWERCASE"
FRPC_FILENAME=frpc

if [ "$1" == preboot ]; then
    FRPC_USERNAME+='-preboot'
    FRPC_FILENAME+='-preboot'
fi

NEW_RANDOM_TOKEN="$(echo $RANDOM | sha512sum | awk '{print $1}')$(echo $RANDOM | sha512sum | awk '{print $1}')"
syncRemoteEnvFileIfUndefined "$PROXY_SSH_STRING" "/home/$PROXY_SSH_USER/frps/frps-tokens.txt" "$FRPC_USERNAME" "$NEW_RANDOM_TOKEN" "$HERE"/temp_code.txt
CHAR_COUNT=$(( "$(echo "$FRPC_USERNAME" | wc -c)" + 1))
TOKEN="$(grep -Eo "^$FRPC_USERNAME=.+" "$HERE"/temp_code.txt | tail -c +$CHAR_COUNT)"
awk -v TOKEN="$TOKEN" '{gsub("put_token_here", TOKEN); print}' "$HERE/$FRPC_FILENAME.template.ini" | envsubst | tee "$HERE/../$FRPC_FILENAME.ini"

if [ "$TOKEN" = "$NEW_RANDOM_TOKEN" ]; then
    echo "WARNING: A new token was generated (no existing token found on the FRPS server). This implies that FRPS has not been set up."
fi
