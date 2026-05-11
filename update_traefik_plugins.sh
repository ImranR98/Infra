#!/bin/bash
set -euo pipefail

# Updates Traefik plugins (only supports GitHub-based plugins)

if ! command -v yq >/dev/null 2>&1; then
    echo "yq is required but not installed. Install it from https://github.com/mikefarah/yq" >&2
    exit 1
fi

PLUGIN_LINES="$(yq '.services.traefik.command' landscape.docker-compose.yaml)"

while IFS= read -r l; do
    PLUGIN_URL="$(echo "$l" | awk -F= '{print $NF}')"
    if ! echo "$PLUGIN_URL" | grep -q 'github.com/'; then
        echo "UNSUPPORTED PLUGIN: $PLUGIN_URL"
        continue
    fi
    PLUGIN_NAME="$(echo "$l" | awk -F. '{print $3}')"
    PLUGIN_CURRENT_VERSION="$(echo "$PLUGIN_LINES" | grep -o "\.plugins\.$PLUGIN_NAME\.version=[^\"]*" | awk -F= '{print $NF}')"
    PLUGIN_LATEST_VERSION="$(curl -s "https://api.github.com/repos$(echo "$PLUGIN_URL" | sed 's|github\.com/||')/releases/latest" | grep -oE 'tag/[^"]+' | head -1 | cut -d/ -f2)"
    if [ "$PLUGIN_CURRENT_VERSION" != "$PLUGIN_LATEST_VERSION" ]; then
        sed -i "s/\.plugins\.$PLUGIN_NAME\.version=$PLUGIN_CURRENT_VERSION/.plugins.$PLUGIN_NAME.version=$PLUGIN_LATEST_VERSION/g" landscape.docker-compose.yaml
        echo "Plugin $PLUGIN_NAME updated to $PLUGIN_LATEST_VERSION (you need to restart Traefik for this to take effect)"
    else
        echo "Plugin $PLUGIN_NAME already on latest ($PLUGIN_LATEST_VERSION)"
    fi
done < <(echo "$PLUGIN_LINES" | grep -o '\.plugins\..*\.modulename=[^"]*')
