#!/bin/bash
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE"/../helpers.sh

generateComposeService strelaysrv > "$HERE"/files/strelaysrv.service
rsync -r "$HERE"/files/ "$PROXY_SSH_STRING":~/strelaysrv/
ssh -A -t "$PROXY_SSH_STRING" "bash '/home/$PROXY_SSH_USER/strelaysrv/install.sh'"