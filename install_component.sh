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

EXCLUSIVE_OPTS_PICKED=0
while getopts "curt" opt; do
    case $opt in
    c) SHELL_ONLY=true ;;
    u)
        UPDATE_MODE=true
        EXCLUSIVE_OPTS_PICKED=$((EXCLUSIVE_OPTS_PICKED + 1))
        ;;
    r)
        REMOVE_MODE=true
        EXCLUSIVE_OPTS_PICKED=$((EXCLUSIVE_OPTS_PICKED + 1))
        ;;
    t)
        UPDATE_CHECK_MODE=true
        EXCLUSIVE_OPTS_PICKED=$((EXCLUSIVE_OPTS_PICKED + 1))
        ;;
    \?) echo "Unrecognized parameter." >&2 && exit 1 ;;
    esac
done
shift $((OPTIND - 1))

if [ $EXCLUSIVE_OPTS_PICKED -gt 1 ]; then
    echo "The -u, -r, and -q parameters are mutually exclusive."
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

if [ "$UPDATE_MODE" = true ] || [ "$UPDATE_CHECK_MODE" = true ]; then
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
if [ -n "$ordered_files" ] || [ "$UPDATE_CHECK_MODE" = true ]; then
    echo ""
    printLine =
    echo "$COMPONENT_NAME"
    printLine =
fi
FIRST_ITEM=true
UPDATE_CHECKING_POSSIBLE=false
UPDATE_AVAILABLE=false
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
    elif [ "$UPDATE_CHECK_MODE" != true ]; then
        printLine -
    fi
    if [ "$UPDATE_CHECK_MODE" = true ]; then
        if [ "$extension" = yaml ]; then
            TEMPLATE_YAML_TAGS="$(sed '/^\s*#/d' "$filepath" | (grep -E '\s*image:' || :) | (grep -Eo 'image: .*' || :))"
            EXISTING_YAML_TAGS="$(grab_existing_k8s_objects_in_file "$filepath" | (grep -E '\s*image:' || :) | (grep -Eo 'image: .*' || :))"
            if [ -z "$TEMPLATE_YAML_TAGS" ]; then
                continue # Not a YAML relevant to update checking
            fi
            if [ "$TEMPLATE_YAML_TAGS" == "$EXISTING_YAML_TAGS" ]; then
                continue # Not a YAML that can reliably be checked for updates
            fi
            UPDATE_CHECKING_POSSIBLE=true
            NEW_YAML_TAGS="$(replaceImageTagsInYAML "$filepath" | (grep -E '\s*image:' || :) | (grep -Eo 'image: .*' || :))"
            if [ "$EXISTING_YAML_TAGS" != "$NEW_YAML_TAGS" ]; then
                UPDATE_AVAILABLE=true
                echo "Update available (based on $file)."
            fi
        elif [ "$extension" = sh ]; then
            # TODO: Helm chart updates
            :
        fi
        continue
    fi
    echo "RUNNING COMMAND: $COMMAND"
    printLine -
    eval "$COMMAND"
    sleep 1 # Make progress easy to follow + allow time for pods to ramp up, etc.
done

if [ "$UPDATE_CHECK_MODE" ]; then
    if [ "$UPDATE_CHECKING_POSSIBLE" != true ]; then
        echo "Cannot reliably check this service for updates."
    elif [ "$UPDATE_AVAILABLE" != true ]; then
        echo "No updates."
    fi    
fi

if [ -n "$ordered_files" ] || [ "$UPDATE_CHECK_MODE" = true ]; then
        printLine =
        echo ""
    fi

if [ -n "$ordered_files" ] && [ -n "$WAIT_AFTER_INSTALL" ]; then
    sleep "$WAIT_AFTER_INSTALL"
fi
