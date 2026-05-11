#!/bin/bash

HERE_L3D9="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

if ! which docker 2>&1 >/dev/null; then
    echo "Docker not found. Please install it." >&2
    exit 1
fi

if [ -f "$HERE_L3D9"/VARS.production.sh ]; then
    MAIN_VARS_FILE="$HERE_L3D9"/VARS.production.sh
elif [ -f "$HERE_L3D9"/VARS.staging.sh ]; then
    MAIN_VARS_FILE="$HERE_L3D9"/VARS.staging.sh
elif [ -f "$HERE_L3D9"/VARS.sh ]; then
    MAIN_VARS_FILE="$HERE_L3D9"/VARS.sh
else
    echo "No VARS.sh file found!" >&2
    exit 1
fi
if ! diff <(grep -Eo '^export [^=]+' "$MAIN_VARS_FILE") <(grep -Eo '^export [^=]+' "$HERE_L3D9"/template.VARS.sh); then
    echo "Your VARS file does not match the template: $MAIN_VARS_FILE" >&2
    exit 1
fi
source "$MAIN_VARS_FILE"
source "$HERE_L3D9"/fixed.VARS.sh
if [ -f "$STATE_DIR"/generated.VARS.sh ]; then
    source "$STATE_DIR"/generated.VARS.sh
fi

findDomainsInSetup() {
    cat "$HERE_L3D9"/landscape.docker-compose.yaml | grep Host | awk -F '`' '{print $2}' | sort | uniq | envsubst
}

generateComposeService() {
    SERVICE_NAME="$1"
    USER_ID="$2"
    if [ -z "$USER_ID" ]; then
        USER_ID="$UID"
    fi
    echo "[Unit]
Description=$SERVICE_NAME start
StartLimitIntervalSec=0

[Service]
User=$USER_ID
Type=idle
ExecStart=/usr/bin/docker compose -p $SERVICE_NAME -f path_to_here/$SERVICE_NAME.docker-compose.yaml up
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target"
}

printLine() {
    linechar="="
    if [ -n "$1" ]; then linechar="$1"; fi
    printf "%0.s"$linechar"" $(seq 1 "$(tput cols 2>/dev/null || :)")
    echo ""
}

printTitle() {
    printLine
    echo "$1"
    printLine
}
