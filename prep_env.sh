#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

if ! command -v docker >/dev/null 2>&1; then
    echo "Docker not found. Please install it." >&2
    exit 1
fi

if [ -f "$HERE"/VARS.production.sh ]; then
    MAIN_VARS_FILE="$HERE"/VARS.production.sh
elif [ -f "$HERE"/VARS.staging.sh ]; then
    MAIN_VARS_FILE="$HERE"/VARS.staging.sh
elif [ -f "$HERE"/VARS.sh ]; then
    MAIN_VARS_FILE="$HERE"/VARS.sh
else
    echo "No VARS.sh file found!" >&2
    exit 1
fi
if ! diff <(grep -Eo '^export [^=]+' "$MAIN_VARS_FILE") <(grep -Eo '^export [^=]+' "$HERE"/template.VARS.sh); then
    echo "Your VARS file does not match the template: $MAIN_VARS_FILE" >&2
    exit 1
fi
source "$MAIN_VARS_FILE"
source "$HERE"/fixed.VARS.sh
if [ -f "$STATE_DIR"/generated.VARS.sh ]; then
    source "$STATE_DIR"/generated.VARS.sh
fi

findDomainsInSetup() {
    cat "$HERE"/compose.yaml | grep Host | awk -F '`' '{print $2}' | sort | uniq | envsubst
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
