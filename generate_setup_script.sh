#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$SCRIPT_DIR"/helpers.sh

while getopts "s:ur" opt; do
    case $opt in
    u) UPDATE_MODE=true ;;
    r) REMOVE_MODE=true ;;
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
    ---
    frps
    frpc
    frpc/frpc-preboot-subcomponent
    ---
    common-pv
    traefik
    authelia
    ---
    crowdsec
    cert-manager
    ---
    monitoring
    ntfy
    logtfy
    logtfy/logtfy-remote-subcomponent
    ---
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
    mosquitto
    homeassistant
    nextcloud
    uptime
    ---
    mdscl
    syncthing
    strelaysrv
    monerod
)

IMMEDIATE_UPDATE_COMPONENTS=(
    homeassistant
    authelia
)

if [ -n "$SINGLE_ITEM" ]; then
    ALL_COMPONENTS=(
        "$SINGLE_ITEM"
    )
else
    echo "#!/bin/bash
set -e
source "$SCRIPT_DIR"/helpers.sh"
    if [ "$UPDATE_MODE" = true ]; then
        echo "export WAIT_AFTER_INSTALL=20

# Run this script to update all components in the cluster."
    elif [ "$REMOVE_MODE" = true ]; then
        echo "export WAIT_AFTER_INSTALL=10

# Run this script to remove some components from the cluster (the ones which support automated removal)."
    else
        echo "export WAIT_AFTER_INSTALL=60

# Run this script to set up the K8s cluster and all components."
    fi
    echo "# This is scripted for convenience, but it is recommended to run each command manually one at a time.
"
fi

if [ "$REMOVE_MODE" = true ]; then
    ALL_COMPONENTS=($(printf "%s\n" "${ALL_COMPONENTS[@]}" | tac))
fi

for component in "${ALL_COMPONENTS[@]}"; do
    if [ "$component" = '---' ]; then
        echo "
read -p 'Paused. Ensure everything so far looks okay, then press Enter to continue... ' anything
"
        continue
    fi
    command="bash '$SCRIPT_DIR/install_component.sh' "
    if contains "$component" "${SHELL_ONLY_COMPONENTS[@]}"; then
        command+="-c "
    fi
    if [ "$UPDATE_MODE" = true ]; then
        command+="-u "
    fi
    if [ "$REMOVE_MODE" = true ]; then
        command+="-r "
    fi
    command+="$component"
    echo "$command"
done

if [ "$UPDATE_MODE" != true ] && [ "$REMOVE_MODE" != true ] && [ -z "$SINGLE_ITEM" ]; then
    echo "
read -p 'Some components need additional manual setup. Look at the logs above for details and take action as needed.
Then press Enter to continue (the relevant components will be updated/restarted)... ' anything
"
    for component in "${IMMEDIATE_UPDATE_COMPONENTS[@]}"; do
        bash "${BASH_SOURCE[0]}" -u -s "$component"
    done
fi

if [ -z "$SINGLE_ITEM" ]; then
    echo "echo Done."
fi
