#!/bin/bash
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE"/../../helpers.sh

cat "$HERE"/../logtfy.template.json | envsubst >"$HERE"/../logtfy.json
jq '.moduleCustomization |= map(select(.module == "ssh_logins" or .module == "port_checker"))
    | .moduleCustomization[] |= if .module == "ssh_logins" then . + {loggerArg: "ssh"} 
    else . + {loggerArg: "localhost 8888", enabled: true} end' "$HERE"/../logtfy.json | jq '.ntfyConfig.defaultConfig as $default | .ntfyConfig.fallbackConfig as $fallback | .ntfyConfig.defaultConfig = $fallback | .ntfyConfig.fallbackConfig = $default' >"$HERE"/files/logtfy.json
cat "$HERE"/files/logtfy.docker-compose.template.yaml | envsubst >"$HERE"/files/logtfy.docker-compose.yaml

generateComposeService logtfy >"$HERE"/files/logtfy.service
rsync -r "$HERE"/files/ "$PROXY_SSH_STRING":~/logtfy/
ssh -A -t "$PROXY_SSH_STRING" "bash '$PROXY_HOME/logtfy/install.sh'"
