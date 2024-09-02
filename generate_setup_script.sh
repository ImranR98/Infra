#!/bin/bash -e

# PROD TODO: Before the final prod deployment, disable remote repo and address all PROD TODOs
# PROD TODO: Remove all instances of 'staging' as a subdomain

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "$SCRIPT_DIR"/helpers.sh

SHELL_ONLY_COMPONENTS=(
    frpc
    docker-compose
)

ALL_COMPONENTS=(
    common-pv
    frpc
    traefik
    prometheus-grafana
    crowdsec
    authelia
    cert-manager
    docker-compose
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
    # nextcloud # Not working
)

echo "#!/bin/bash -e

# Run these commands to set up the K8s cluster and all services.
# These are not provided as a pre-made script as manually running one command at a time is less error-prone.
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
    command+="$component"
    echo "$command"
done
