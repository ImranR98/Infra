#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

if ! command -v docker >/dev/null 2>&1; then
    echo "Docker not found. Please install it." >&2
    exit 1
fi

MAIN_VARS_FILE="$HERE"/VARS.sh
if [ ! -f "$MAIN_VARS_FILE" ]; then
    echo "No VARS.sh file found! Copy template.VARS.sh to VARS.sh and fill in the values." >&2
    exit 1
fi
while IFS= read -r var; do
    if ! grep -q "^export $var=" "$MAIN_VARS_FILE"; then
        echo "Your VARS file is missing required variable: $var" >&2
        echo "File: $MAIN_VARS_FILE" >&2
        exit 1
    fi
done < <(grep -Eo '^export [^=]+' "$HERE"/template.VARS.sh | sed 's/^export //')

source "$MAIN_VARS_FILE"
export MY_UID="$UID"
export NODE_NAME_LOWERCASE="${NODE_NAME,,}"
export SUDO_COMMAND="sudo"
if command -v run0 >/dev/null 2>&1; then
    export SUDO_COMMAND="run0"
fi
if [ -f "$STATE_DIR"/generated.VARS.sh ]; then
    source "$STATE_DIR"/generated.VARS.sh
fi

findDomainsInSetup() {
    grep Host "$HERE"/compose.yaml | awk -F '`' '{print $2}' | sort | uniq | envsubst
}

generateComposeService() {
    SERVICE_NAME="$1"
    USER_ID="$2"
    COMPOSE_DIR="$3"
    if [ -z "$USER_ID" ]; then
        USER_ID="$UID"
    fi
    echo "[Unit]
Description=$SERVICE_NAME start
StartLimitIntervalSec=0

[Service]
User=$USER_ID
Type=idle
ExecStart=/usr/bin/docker compose -p $SERVICE_NAME -f $COMPOSE_DIR/compose.yaml up
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target"
}

printLine() {
    local linechar="${1:-=}"
    local cols
    cols=$(tput cols 2>/dev/null) || cols=80
    printf '%*s' "$cols" '' | tr ' ' "$linechar"
    echo ""
}

printTitle() {
    printLine
    echo "$1"
    printLine
}
