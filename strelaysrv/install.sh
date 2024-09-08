#!/bin/bash
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE"/../helpers.sh

generateComposeService strelaysrv > "$HERE"/files/strelaysrv.service
cat "$HERE"/files/strelaysrv.docker-compose.template.yaml | envsubst > "$HERE"/files/strelaysrv.docker-compose.yaml
rsync -r "$HERE"/files/ "$PROXY_SSH_STRING":~/strelaysrv/
ssh -A -t "$PROXY_SSH_STRING" "bash '/home/$PROXY_USER/strelaysrv/install.sh'"