#!/bin/bash

# This script prepares the shell environment for other scripts. It:
# - Ensures all environment variables are loaded
# - Defines helper functions

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

contains() {
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

rsyncWithChownContent() {
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
    $SUDO_COMMAND rsync -ar "$ORIGIN"/ "$DESTINATION"/
    $SUDO_COMMAND chown "$OWNER" -R "$DESTINATION"/*
    $SUDO_COMMAND chgrp "$GROUP" -R "$DESTINATION"/*
}

syncRemoteEnvFileIfUndefined() {
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

    scp -q "$SSH_STRING":"$PATH_ON_REMOTE" "$LOCAL_ENV_FILE"
}

pullComposeImages() {
    COMPOSE_FILE="$1"
    grep '    image: ' "$COMPOSE_FILE" | awk '{print $NF}' | while read item; do
        docker pull "$item"
    done
    echo "NOTE: This script assumes all images in "$(dirname "$COMPOSE_FILE")" are tagged with a non version-specific tag (like 'latest')."
}

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

parseImageLine() {
    LINE="$1"
    if [ -z "$(echo "$LINE" | awk '{print $2}')" ]; then
        LINE="image: $LINE"
    fi
    IMAGE=$(echo "$LINE" | awk '{print $2}')
    NAMESPACE="$(echo "$IMAGE" | awk -F'/' '{print $(NF-1)}' || :)"
    if [ "$(echo "$IMAGE" | awk -F'/' '{print NF}')" = 1 ]; then
        NAMESPACE='library'
    fi
    REPOSITORY_TAG="$(echo "$IMAGE" | awk -F'/' '{print $NF}')"
    ORIGIN="$(echo $IMAGE | head -c -$(($(echo "$NAMESPACE/$REPOSITORY_TAG" | wc -c) + 1)))"
    REPOSITORY="$(echo "$REPOSITORY_TAG" | awk -F':' '{print $1}')"
    TAG=$(echo "$IMAGE" | awk -F':' '{print $2}')
    if [ -z "$TAG" ]; then
        TAG='latest'
    fi
    echo "$NAMESPACE $REPOSITORY $TAG $ORIGIN"
}

archForDocker() {
    arch | sed s/aarch64/arm64/ | sed s/x86_64/amd64/
}

getDockerHubImageDigest() {
    NAMESPACE="$1"
    REPOSITORY="$2"
    TAG="$3"
    DIGEST=$(curl -s "https://hub.docker.com/v2/namespaces/$NAMESPACE/repositories/$REPOSITORY/tags?name=$TAG" | jq -r ".results[] | select(.name == \""$TAG\"") | .images[] | select(.architecture == \"$(archForDocker)\") | .digest")
    if [[ -z "$DIGEST" || "$DIGEST" == "null" ]]; then
        echo "Error: Could not fetch digest for image $NAMESPACE/$REPOSITORY:$TAG" >&2
    fi
    echo "$DIGEST"
}

getGHCRImageDigest() {
    NAMESPACE="$1"
    REPOSITORY="$2"
    TAG="$3"
    TOKEN="$(
        curl -s "https://ghcr.io/token?scope=repository:$NAMESPACE/$REPOSITORY:pull" |
            awk -F'"' '$0=$4'
    )"
    curl -s -H "Authorization: Bearer $TOKEN" -H 'Accept: application/vnd.oci.image.index.v1+json' "https://ghcr.io/v2/$NAMESPACE/$REPOSITORY/manifests/$TAG" | jq -r ".manifests[] | select(.platform.architecture == \"$(archForDocker)\") | .digest"
}

getGitlabImageDigest() {
    NAMESPACE="$1"
    REPOSITORY="$2"
    TAG="$3"
    ID="$(
        curl -s "https://gitlab.com/api/v4/projects/$NAMESPACE%2F$REPOSITORY/registry/repositories" |
            jq -r ".[] | select(.path == \""$NAMESPACE/$REPOSITORY\"") | .id"
    )"
    curl -s https://gitlab.com/api/v4/projects/$NAMESPACE%2F$REPOSITORY/registry/repositories/$ID/tags/$TAG | jq -r '.digest'
}

putHashInImageLineIfPossible() {
    LINE="$1"
    IS_SUPPORTED=false
    if [ "$(echo "$LINE" | awk '{print NF}')" -le 2 ] || [ "$(echo "$LINE" | awk -F '/' '{print $1}')" = 'ghcr.io' ]; then
        IS_SUPPORTED=true
    fi
    if [ "$IS_SUPPORTED" != true ]; then
        echo "$LINE"
    else
        read -r NAMESPACE REPOSITORY TAG ORIGIN <<<"$(parseImageLine "$LINE")"
        if [ -z "$ORIGIN" ]; then
            DIGEST=$(getDockerHubImageDigest "$NAMESPACE" "$REPOSITORY" "$TAG")
        elif [ "$ORIGIN" = 'ghcr.io' ]; then
            DIGEST=$(getGHCRImageDigest "$NAMESPACE" "$REPOSITORY" "$TAG")
        elif [ "$ORIGIN" = 'registry.gitlab.com' ]; then
            DIGEST=$(getGitlabImageDigest "$NAMESPACE" "$REPOSITORY" "$TAG")
        else
            echo "$LINE"
            exit
        fi
        OLD_NAMESPACE_SLASH="$NAMESPACE/"
        NEW_NAMESPACE_SLASH="$NAMESPACE/"
        if [ "$OLD_NAMESPACE_SLASH" = 'library/' ] && [[ ! "$LINE" =~ library ]] && [ -z "$ORIGIN" ]; then
            OLD_NAMESPACE_SLASH=''
            NEW_NAMESPACE_SLASH=''
        fi
        OLD_IMAGE="$(echo "${OLD_NAMESPACE_SLASH}$REPOSITORY" | sed 's/\//\\\//g')"
        if [ "$(echo "$LINE" | awk -F':' '{print $NF}')" = "$TAG" ]; then
            OLD_IMAGE="$OLD_IMAGE:$TAG"
        fi
        NEW_IMAGE="$(echo "${NEW_NAMESPACE_SLASH}$REPOSITORY" | sed 's/\//\\\//g')@$DIGEST"
        echo "$LINE" | sed "s|$OLD_IMAGE|$NEW_IMAGE|"
    fi
}

replaceImageTagsInYAML() {
    FILE="$1"
    while IFS= read -r LINE || [ -n "$LINE" ]; do
        if [[ "$LINE" =~ ^\s*# ]]; then
            continue
        fi
        if echo "$LINE" | grep -Eq '\s*image:' && ! echo "$LINE" | grep -q '@'; then
            putHashInImageLineIfPossible "$LINE"
        else
            echo "$LINE"
        fi
    done <"$FILE"
}

mergeYaml() {
    local file1="$1"
    local file2="$2"

    if ! command -v yq &>/dev/null; then
        echo "Error: yq is not installed. Install it first." >&2
        return 1
    fi

    if [[ ! -f "$file1" || ! -f "$file2" ]]; then
        echo "Error: Both input YAML files must exist." >&2
        return 1
    fi

    # Merge file2 into file1, preserving arrays by appending instead of replacing
    yq eval-all 'select(fileIndex == 0) *+ select(fileIndex == 1)' "$file1" "$file2" >"${file1}.tmp" && mv "${file1}.tmp" "$file1"

    echo "Merged YAML saved to $file1"
}
