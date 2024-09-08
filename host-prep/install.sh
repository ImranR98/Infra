#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

scp "$HERE"/files/prep.sh "$PROXY_SSH_STRING":~/prep.sh

bash "$HERE"/files/prep.sh "$MAIN_NODE_HOSTNAME" "$ADMIN_PUBLIC_SSH_KEY"
ssh -A -t "$PROXY_SSH_STRING" "bash ~/prep.sh '$PROXY_NODE_HOSTNAME' '$ADMIN_PUBLIC_SSH_KEY'"

