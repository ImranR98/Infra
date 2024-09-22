#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$HERE"/helpers.sh
if [ -f "$HERE"/VARS.production.sh ]; then
    source "$HERE"/VARS.production.sh
elif [ -f "$HERE"/VARS.staging.sh ]; then
    source "$HERE"/VARS.staging.sh
elif [ -f "$HERE"/VARS.sh ]; then
    source "$HERE"/VARS.sh
else
    echo "No VARS.sh file found!" >&2
    exit 1
fi
source "$HERE"/fixed.VARS.sh

while getopts "cur" opt; do
    case $opt in
    c) SHELL_ONLY=true ;;
    u) UPDATE_MODE=true ;;
    r) REMOVE_MODE=true ;;
    \?) echo "Unrecognized parameter." >&2 && exit 1 ;;
    esac
done
shift $((OPTIND - 1))

if [ "$UPDATE_MODE" = true ] && [ "$REMOVE_MODE" = true ]; then
    echo "You can only use either -u or -r for update mode or remove mode respectively."
    exit 1
fi

# Get component dir
COMPONENT_DIR="$(realpath "$1")"
COMPONENT_NAME="$(basename "$COMPONENT_DIR")"

# Constants
START_WITH_FILES=(prep.sh pv.yaml nfs.yaml db.yaml secrets.yaml configmaps.yaml install.sh "$COMPONENT_NAME.yaml")
END_WITH_FILES=(middlewares.yaml ingress.yaml post_install.sh)
IGNORE_FILES=(pre_uninstall.sh uninstall.sh values.yaml update.sh)
INCLUDE_OTHER_FILES=true

if [ "$UPDATE_MODE" = true ]; then
    START_WITH_FILES=(pv.yaml nfs.yaml db.yaml secrets.yaml configmaps.yaml "$COMPONENT_NAME.yaml" update.sh)
    END_WITH_FILES=(middlewares.yaml ingress.yaml)
    IGNORE_FILES=()
    INCLUDE_OTHER_FILES=false # Since this is false we don't need to specify any IGNORE_FILES
fi

if [ "$REMOVE_MODE" ]; then
    START_WITH_FILES=(pre_uninstall.sh uninstall.sh "$COMPONENT_NAME.yaml" configmaps.yaml secrets.yaml db.yaml nfs.yaml pv.yaml middlewares.yaml ingress.yaml)
    END_WITH_FILES=()
    IGNORE_FILES=()
    INCLUDE_OTHER_FILES=false
fi

# Validate arg
if [ ! -d "$COMPONENT_DIR" ]; then
    echo "Dir not found: $COMPONENT_DIR" >&2
    exit 1
fi

# Order the files
ordered_files=()
for file in "${START_WITH_FILES[@]}"; do
    if [ -f "$COMPONENT_DIR/$file" ]; then
        ordered_files+=("$file")
    fi
done
if [ "$INCLUDE_OTHER_FILES" = true ]; then
    for file in "$COMPONENT_DIR"/*.{yaml,sh}; do
        [ -e "$file" ] || continue # For cases when there are no yaml/sh files (ignore the bad ls output)
        basefile=$(basename "$file")
        if ! contains "$basefile" "${ordered_files[@]}" && ! contains "$basefile" "${START_WITH_FILES[@]}" && ! contains "$basefile" "${END_WITH_FILES[@]}" && ! contains "$basefile" "${IGNORE_FILES[@]}"; then
            ordered_files+=("$basefile")
        fi
    done
fi
for file in "${END_WITH_FILES[@]}"; do
    if [ -f "$COMPONENT_DIR/$file" ]; then
        ordered_files+=("$file")
    fi
done

# Process each file to install the component
if [ -n "$ordered_files" ]; then
    echo ""
    printLine =
    echo "$COMPONENT_NAME"
    printLine =
fi
FIRST_ITEM=true
for file in "${ordered_files[@]}"; do
    filepath="$COMPONENT_DIR/$file"
    extension="${file##*.}"
    if [ "$extension" != sh ] && [ "$SHELL_ONLY" = true ]; then
        continue
    fi
    if [ "$extension" = yaml ]; then
        COMMAND_ACTION="apply"
        if [ "$REMOVE_MODE" = true ]; then COMMAND_ACTION="delete"; fi
        COMMAND="kubectl $COMMAND_ACTION -f <(replaceImageTagsInYAML "$filepath" | envsubst)"
    elif [ "$extension" = sh ]; then
        COMMAND="bash "$filepath""
    fi
    if [ "$FIRST_ITEM" = true ]; then
        FIRST_ITEM=false
    else
        printLine -
    fi
    echo "RUNNING COMMAND: $COMMAND"
    printLine -
    eval "$COMMAND"
    sleep 1 # Make progress easy to follow + allow time for pods to ramp up, etc.
done
if [ -n "$ordered_files" ]; then
    printLine =
    echo ""
fi

if [ -n "$ordered_files" ] && [ -n "$WAIT_AFTER_INSTALL" ]; then
    sleep "$WAIT_AFTER_INSTALL"
fi
