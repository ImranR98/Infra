#!/bin/bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

export MY_UID="$UID"
export MAIN_NODE_HOSTNAME_LOWERCASE="${MAIN_NODE_HOSTNAME,,}"

export SUDO_COMMAND="sudo"
if command -v run0 >/dev/null 2>&1; then
    export SUDO_COMMAND="run0"
fi
