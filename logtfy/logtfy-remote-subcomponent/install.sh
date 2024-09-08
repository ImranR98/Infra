#!/bin/bash
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE"/../../helpers.sh

cat "$HERE"/../logtfy.template.json | envsubst > "$HERE"/../logtfy.json
jq '.moduleCustomization = [.moduleCustomization[] | select(.module == "ssh_logins") | .loggerArg = "ssh"]' "$HERE"/../logtfy.json > "$HERE"/files/logtfy.json
cat "$HERE"/files/logtfy.docker-compose.template.yaml | envsubst > "$HERE"/files/logtfy.docker-compose.yaml

generateComposeService logtfy > "$HERE"/files/logtfy.service
rsync -r "$HERE"/files/ "$PROXY_SSH_STRING":~/logtfy/
ssh -A -t "$PROXY_SSH_STRING" "bash '/home/$PROXY_USER/logtfy/install.sh'"