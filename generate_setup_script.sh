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
    frps
    frpc
    logtfy
    syncthing
)

ALL_COMPONENTS=(
    frps
    frpc
    common-pv
    traefik
    prometheus-grafana
    crowdsec
    authelia
    cert-manager
    logtfy
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
)

echo "#!/bin/bash
set -e
"
if [ "$UPDATE_MODE" = true ]; then
    echo "# Run these commands to update all services in the cluster."
else
    echo "# Run these commands to set up the K8s cluster and all services."
fi
echo "# These are not provided as a pre-made script since manually running one command at a time is less error-prone.
"

TEMP_CODE=0
(
    kubectl get nodes >/dev/null 2>&1
) || TEMP_CODE=$?
if [ "$TEMP_CODE" != 0 ]; then
    echo "bash '$SCRIPT_DIR/install_k8s.sh' master"
    echo "bash '$SCRIPT_DIR/prep_cluster.sh'"
    echo ""
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
