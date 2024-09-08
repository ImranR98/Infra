#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$SCRIPT_DIR"/helpers.sh

while getopts "u" opt; do
    case $opt in
    u) UPDATE_MODE=true ;;
    \?) echo "Unrecognized parameter." >&2 && exit 1 ;;
    esac
done
shift $((OPTIND - 1))

SHELL_ONLY_COMPONENTS=(
    host-prep
    cluster-base
    frps
    frpc
    frpc/frpc-preboot-subcomponent
    logtfy
    logtfy/logtfy-remote-subcomponent
    syncthing
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
    logtfy
    logtfy/logtfy-remote-subcomponent
    syncthing
    ntfy
    filebrowser
    immich
    jellyfin
    navidrome
    plausible
    monerod
    ollama
    pixelntfy
    isbn-lookup
    dscpln-parsebalx
    send
    opencanary
    uptime
    mdscl
    mosquitto
    homeassistant
    nextcloud
    strelaysrv
)

echo "#!/bin/bash
set -e
"
if [ "$UPDATE_MODE" = true ]; then
    echo "# Run these commands to update all components in the cluster."
else
    echo "# Run these commands to set up the K8s cluster and all components."
fi
echo "# These are not provided as a pre-made script since manually running one command at a time is less error-prone.
"

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
