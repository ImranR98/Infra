
#!/bin/bash
set -e

# Updates Traefik plugins (only supports GitHub-based plugins)

PLUGIN_LINES="$(yq '.services.traefik.command' landscape.docker-compose.yaml)"

for l in $(echo "$PLUGIN_LINES" | grep -o '\.plugins\..*\.modulename=[^"]*'); do
	PLUGIN_URL="$(echo "$l" | awk -F= '{print $NF}')"
	if [[ ! "$PLUGIN_URL" =~ 'github.com/' ]]; then echo "UNSUPPORTED PLUGIN: $PLUGIN_URL" continue; fi
	PLUGIN_NAME="$(echo "$l" | awk -F. '{print $3}')"
	PLUGIN_CURRENT_VERSION="$(echo "$PLUGIN_LINES" | grep -o "\.plugins\.$PLUGIN_NAME\.version=[^\"]*" | awk -F= '{print $NF}')"
	PLUGIN_LATEST_VERSION="$(curl -s https://api.github.com/repos$(echo $PLUGIN_URL | sed s/github\.com//g'')/releases/latest | grep -oE 'tag/.*' | tail -c +5 | head -c -3)"
	if [ "$PLUGIN_CURRENT_VERSION" != "$PLUGIN_LATEST_VERSION" ]; then
		sed -i "s/\.plugins\.$PLUGIN_NAME\.version=$PLUGIN_CURRENT_VERSION/.plugins.$PLUGIN_NAME.version=$PLUGIN_LATEST_VERSION/g" landscape.docker-compose.yaml
		echo "Plugin $PLUGIN_NAME updated to $PLUGIN_LATEST_VERSION (you need to restart Traefik for this to take effect)"
	else
		echo "Plugin $PLUGIN_NAME already on latest ($PLUGIN_LATEST_VERSION)"
	fi
done