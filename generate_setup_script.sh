#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$SCRIPT_DIR"/helpers.sh

while getopts "s:u" opt; do
    case $opt in
    u) UPDATE_MODE=true ;;
    s) SINGLE_ITEM="$OPTARG" ;;
    \?) echo "Unrecognized parameter." >&2 && exit 1 ;;
    esac
done
shift $((OPTIND - 1))

SHELL_ONLY_COMPONENTS=(
    host-prep
    cluster-base
    frps
    frpc/frpc-preboot-subcomponent
    logtfy/logtfy-remote-subcomponent
    strelaysrv
)

ALL_COMPONENTS=(
    host-prep
    cluster-base
    frps
    frpc
    frpc/frpc-preboot-subcomponent
    common-pv
    traefik
    authelia
    crowdsec
    cert-manager
    prometheus-grafana
    ntfy
    logtfy
    logtfy/logtfy-remote-subcomponent
    syncthing
    filebrowser
    immich
    jellyfin
    navidrome
    plausible
    ollama
    pixelntfy
    isbn-lookup
    dscpln-parsebalx
    send
    opencanary
    mdscl
    mosquitto
    homeassistant
    nextcloud
    uptime
    strelaysrv
    monerod
)

IMMEDIATE_UPDATE_COMPONENTS=(
    authelia
    homeassistant
)

if [ -n "$SINGLE_ITEM" ]; then
    ALL_COMPONENTS=(
        "$SINGLE_ITEM"
    )
else
    if [ "$UPDATE_MODE" = true ]; then
        echo "# Run the following commands to update all components in the cluster."
    else
        echo "# Run the following commands to set up the K8s cluster and all components."
    fi
    echo "# These are meant to be run manually, one line at a time (not as a single script).
"
fi

for component in "${ALL_COMPONENTS[@]}"; do
    command="bash '$SCRIPT_DIR/install_component.sh' "
    if contains "$component" "${SHELL_ONLY_COMPONENTS[@]}"; then
        command+="-c "
    fi
    if [ "$UPDATE_MODE" = true ]; then
        command+="-u "
    fi
    command+="$component"
    echo "$command"
done

if [ "$UPDATE_MODE" != true ] && [ -z "$SINGLE_ITEM" ]; then
    echo "
# Keep an eye on the console output while commands run, since some may require further manual steps.

# After running manual steps as specified, you must run these commands to update/restart specific services:"
    for component in "${IMMEDIATE_UPDATE_COMPONENTS[@]}"; do
        bash "${BASH_SOURCE[0]}" -u -s "$component"
    done
fi
