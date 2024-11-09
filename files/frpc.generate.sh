#!/bin/bash
set -e

HERE_QC6O="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd;)"
source "$HERE_QC6O"/../prep_env.sh

FRPC_USERNAME="$MAIN_NODE_HOSTNAME_LOWERCASE"
FRPC_FILENAME=frpc

if [ "$1" == preboot ]; then
    FRPC_USERNAME+='-preboot'
    FRPC_FILENAME+='-preboot'
fi

NEW_RANDOM_TOKEN="$(echo $RANDOM | sha512sum | awk '{print $1}')$(echo $RANDOM | sha512sum | awk '{print $1}')"
syncRemoteEnvFileIfUndefined "$PROXY_SSH_STRING" "$PROXY_HOME/landscape-remote-services/state/frps-tokens.txt" "$FRPC_USERNAME" "$NEW_RANDOM_TOKEN" "$HERE_QC6O"/temp_code.txt
CHAR_COUNT=$(( "$(echo "$FRPC_USERNAME" | wc -c)" + 1))
TOKEN="$(grep -Eo "^$FRPC_USERNAME=.+" "$HERE_QC6O"/temp_code.txt | tail -c +$CHAR_COUNT)"
awk -v TOKEN="$TOKEN" '{gsub("put_token_here", TOKEN); print}' "$HERE_QC6O/$FRPC_FILENAME.template.ini" | envsubst | dd status=none of="$HERE_QC6O/$FRPC_FILENAME.ini"
rm "$HERE_QC6O"/temp_code.txt

if [ "$TOKEN" = "$NEW_RANDOM_TOKEN" ]; then
    echo "WARNING: A new token was generated (no existing token found on the FRPS server). This implies that FRPS has not been set up."
fi