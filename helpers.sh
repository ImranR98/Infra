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
        echo "$(cat "$ingress" | grep Host | awk -F '`' '{print $2}')" >>"$LIST_FILE"
    done
    find . 2>/dev/null | grep -E '\.sh$' | while read -r install; do
        DOMAIN="$(cat "$install" | grep '^SSH_HOST=' | awk -F '=' '{print $2}')"
        if [ -n "$DOMAIN" ]; then
            echo "$DOMAIN" >>"$LIST_FILE"
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

printLine() {
    linechar="="
    if [ -n "$1" ]; then linechar="$1"; fi
    printf "%0.s"$linechar"" $(seq 1 "$(tput cols)")
    echo ""
}

parseImageLine() {
    LINE="$1"
    if [ -z "$(echo "$LINE" | awk '{print $2}')" ]; then
        LINE="image: $LINE"
    fi
    IMAGE=$(echo "$LINE" | awk '{print $2}')
    if [ -n "$(echo "$IMAGE" | grep '/')" ]; then
        NAMESPACE=$(echo "$IMAGE" | awk -F'/' '{print $1}')
        REPOSITORY=$(echo "$IMAGE" | awk -F'/' '{print $2}' | awk -F':' '{print $1}')
    else
        NAMESPACE="library"
        REPOSITORY=$(echo "$IMAGE" | awk -F':' '{print $1}')
    fi
    TAG=$(echo "$IMAGE" | awk -F':' '{print $2}')
    if [ -z "$TAG" ]; then
        TAG="latest"
    fi
    echo "$NAMESPACE $REPOSITORY $TAG"
}

getImageDigest() {
    NAMESPACE="$1"
    REPOSITORY="$2"
    TAG="$3"
    DIGEST=$(curl -s "https://hub.docker.com/v2/namespaces/$NAMESPACE/repositories/$REPOSITORY/tags?name=$TAG" | jq -r '.results[0].images[] | select(.architecture == "amd64") | .digest')
    if [[ -z "$DIGEST" || "$DIGEST" == "null" ]]; then
        echo "Error: Could not fetch digest for image $NAMESPACE/$REPOSITORY:$TAG" >&2
    fi
    echo "$DIGEST"
}

replaceImageTagsInYAML() {
    FILE="$1"
    while IFS= read -r LINE || [ -n "$LINE" ]; do
        if [[ "$LINE" =~ ^\s*# ]]; then
            continue
        fi
        if echo "$LINE" | grep -Eq '\s*image:' && ! echo "$LINE" | grep -q '@' && [ -z "$(echo "$LINE" | awk -F '/' '{print $3}')" ]; then
            read -r NAMESPACE REPOSITORY TAG <<<"$(parseImageLine "$LINE")"
            DIGEST=$(getImageDigest "$NAMESPACE" "$REPOSITORY" "$TAG")
            OLD_NAMESPACE="$NAMESPACE/"
            if [ "$OLD_NAMESPACE" = 'library/' ] && [[ ! "$LINE" =~ library ]]; then
                OLD_NAMESPACE=''
            fi
            OLD_IMAGE="$(echo "${OLD_NAMESPACE}$REPOSITORY:$TAG" | sed 's/\//\\\//g')"
            NEW_IMAGE="$NAMESPACE/$REPOSITORY@$DIGEST"
            echo "$LINE" | sed "s|$OLD_IMAGE|$NEW_IMAGE|"
        else
            echo "$LINE"
        fi
    done <"$FILE"
}

grab_existing_k8s_objects_in_file() {
    local manifest_file="$1"
    sed '/^\s*#/d' "$manifest_file" | kubectl apply --dry-run=client -f - -o json | (jq -c '.items[]' 2>/dev/null || :) | while read -r object; do
        kind=$(echo "$object" | jq -r '.kind')
        name=$(echo "$object" | jq -r '.metadata.name')
        namespace=$(echo "$object" | jq -r '.metadata.namespace // "default"') # Default to "default" namespace if not present
        if kubectl get "$kind" "$name" -n "$namespace" >/dev/null 2>&1; then
            kubectl get "$kind" "$name" -n "$namespace" -o yaml
        fi
    done
}

deletePodsByGrep() {
    if [ -n "$1" ]; then
        for pod in $(kubectl -n production get pod | grep "$1" | awk '{print $1}'); do
            kubectl -n production delete pod "$pod"
        done
    fi
}
