#!/bin/bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

export MY_UID="$UID"
export MAIN_NODE_HOSTNAME_LOWERCASE="${MAIN_NODE_HOSTNAME,,}"

export SERVICES_TLS_NAME="$(echo "$SERVICES_TOP_DOMAIN" | sed 's/\./-/g')"

export SUDO_COMMAND="sudo"
if which rpm-ostree 2>&1 >/dev/null; then
    export SUDO_COMMAND="run0"
fi
