#!/bin/bash
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE"/../helpers.sh

SSH_USER=$USER
SSH_HOST=staging.example.org
SSH_STRING="$SSH_USER@$SSH_HOST"

syncRemoteEnvFileIfUndefined "$SSH_STRING" "/home/$SSH_USER/frps/frps-tokens.txt" "frontier" "$(echo $RANDOM | sha512sum | awk '{print $1}')$(echo $RANDOM | sha512sum | awk '{print $1}')" "$HERE"/files/frps-tokens.txt

generateComposeService frps > "$HERE"/files/frps.service
rsync -r "$HERE"/files/ "$SSH_STRING":~/frps/

ssh -A -t "$SSH_STRING" "bash '/home/$SSH_USER/frps/install.sh'"