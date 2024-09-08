#!/bin/bash

function contains() {
    local item="$1"
    shift
    local arr=("$@")

    for element in "${arr[@]}"; do
        if [[ "$element" == "$item" ]]; then
            return 0
        fi
    done

    return 1
}

function rsyncWithChownContent() {
    ORIGIN="$1"
    if [ ! -d "$ORIGIN" ]; then
        echo "No/Invalid origin directory!" >&2
        exit 1
    fi
    DESTINATION="$2"
    if [ ! -d "$DESTINATION" ]; then
        echo "No/Invalid destination directory!" >&2
        exit 1
    fi
    OWNER="$3"
    GROUP="$4"
    if [ -z "$OWNER" ]; then
        OWNER=$UID
    fi
    if [ -z "$GROUP" ]; then
        GROUP=$UID
    fi
    mkdir -p "$DESTINATION"
    sudo rsync -ar "$ORIGIN"/ "$DESTINATION"/
    sudo chown "$OWNER" -R "$DESTINATION"/*
    sudo chgrp "$GROUP" -R "$DESTINATION"/*
}

function syncRemoteEnvFileIfUndefined() {
    # Given an env file on a remote server (any file where each line is '<varname>=<varvalue>'),
    # If the file already defines a given var, don't change it,
    # But if not, update it with a given value
    # Then sync (replace) a given local env file with the remote one
    SSH_STRING="$1"
    PATH_ON_REMOTE="$2"
    ENV_VAR_NAME="$3"
    VALUE_IF_UNDEFINED="$4"
    LOCAL_ENV_FILE="$5"

    ssh "$SSH_STRING" "mkdir -p "$(dirname "$PATH_ON_REMOTE")""
    FILE_CONTENT="$(ssh "$SSH_STRING" "cat '$PATH_ON_REMOTE' 2>/dev/null || :")"
    VAR_VAL="$( (echo "$FILE_CONTENT" | grep -E "^$ENV_VAR_NAME=") || :)"
    if [ -z "$VAR_VAL" ]; then
        VAR_VAL="$ENV_VAR_NAME=$VALUE_IF_UNDEFINED"
        ssh "$SSH_STRING" "echo '$VAR_VAL' >> '$PATH_ON_REMOTE'"
    fi

    scp "$SSH_STRING":"$PATH_ON_REMOTE" "$LOCAL_ENV_FILE"
}

pullComposeImages() {
    COMPOSE_FILE="$1"
    grep '    image: ' "$COMPOSE_FILE" | awk '{print $NF}' | while read item; do
        docker pull "$item"
    done
    echo "NOTE: This script assumes all images in "$(dirname "$COMPOSE_FILE")" are tagged with a non version-specific tag (like 'latest')."
}

findDomainsInSetup() {
    LIST_FILE="$(mktemp)"
    find . 2>/dev/null | grep -E 'ingress\.yaml$' | while read -r ingress; do
        echo "$(cat "$ingress" | grep Host | awk -F '`' '{print $2}')" >> "$LIST_FILE"
    done
    find . 2>/dev/null | grep -E '\.sh$' | while read -r install; do
        DOMAIN="$(cat "$install" | grep '^SSH_HOST=' | awk -F '=' '{print $2}')"
        if [ -n "$DOMAIN" ]; then
            echo "$DOMAIN" >> "$LIST_FILE"
        fi
    done
    cat "$LIST_FILE" | sort | uniq
    rm "$LIST_FILE"
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
ExecStart=/usr/bin/docker compose -f path_to_here/$SERVICE_NAME.docker-compose.yaml up
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target"
}