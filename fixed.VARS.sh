#!/bin/bash

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

export MY_UID="$UID"
export NODE_NAME_LOWERCASE="${NODE_NAME,,}"

export SUDO_COMMAND="sudo"
if command -v run0 >/dev/null 2>&1; then
    export SUDO_COMMAND="run0"
fi
