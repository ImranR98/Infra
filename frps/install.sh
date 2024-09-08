#!/bin/bash
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE"/../helpers.sh

syncRemoteEnvFileIfUndefined "$PROXY_SSH_STRING" "/home/$PROXY_USER/frps/frps-tokens.txt" "$MAIN_NODE_HOSTNAME_LOWERCASE" "$(echo $RANDOM | sha512sum | awk '{print $1}')$(echo $RANDOM | sha512sum | awk '{print $1}')" "$HERE"/files/frps-tokens.txt

generateComposeService frps 1000 > "$HERE"/files/frps.service
rsync -r "$HERE"/files/ "$PROXY_SSH_STRING":~/frps/

ssh -A -t "$PROXY_SSH_STRING" "bash '/home/$PROXY_USER/frps/install.sh'"