#!/bin/bash
# Traefik plugin updater — works across both Compose and K3s stacks.
# Sourced by commands/update-traefik-plugins.sh.  Requires common.sh.

# ---- Traefik plugin updater ----
# Unified: detects whether compose, k3s, or both exist for this target.

update_traefik_plugins() {
	local target="${1:-$TARGET}"

	for cmd in yq jq; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			echo "$cmd is required but not installed." >&2
			return 1
		fi
	done

	_update_plugin_version() {
		local url="$1" name="$2" current="$3"
		if ! echo "$url" | grep -q 'github.com/'; then
			echo "  UNSUPPORTED PLUGIN: $url" >&2
			return
		fi
		local latest
		latest="$(curl -fsSL --connect-timeout 10 --max-time 30 "https://api.github.com/repos/$(echo "$url" | sed 's|github\.com/||')/releases/latest" | jq -r '.tag_name')"
		if [ "$current" != "$latest" ]; then
			echo "  $name: $current → $latest"
			echo "$name:$url:$current:$latest"
		else
			echo "  $name already latest ($latest)"
		fi
	}

	# Compose path
	local compose_file="$ATLAS_ROOT/targets/$target/compose/compose.yaml"
	if [ -f "$compose_file" ]; then
		echo "=== Compose: $target ==="
		local plugin_lines
		plugin_lines="$(yq '.services.traefik.command' "$compose_file" 2>/dev/null)"
		if [ -n "$plugin_lines" ] && [ "$plugin_lines" != "null" ]; then
			while IFS= read -r l; do
				[ -z "$l" ] && continue
				local purl="$(echo "$l" | awk -F= '{print $NF}')"
				local pname="$(echo "$l" | awk -F. '{print $3}')"
				local pver="$(echo "$plugin_lines" | grep -o "\.plugins\.$pname\.version=[^\"]*" | awk -F= '{print $NF}')"
				local result
				result="$(_update_plugin_version "$purl" "$pname" "$pver")"
				local newver
				newver="$(echo "$result" | grep "^$pname:" | cut -d: -f4)"
				if [ -n "$newver" ]; then
					sed -i "s/\.plugins\.$pname\.version=$pver/.plugins.$pname.version=$newver/g" "$compose_file"
					echo "  Updated $pname → $newver (restart Traefik to apply)"
				fi
			done < <(echo "$plugin_lines" | grep -o '\.plugins\..*\.modulename=[^"]*')
		fi
	fi

	# K3s path: parse HelmChartConfig valuesContent for plugin entries
	local traefik_yaml="$ATLAS_ROOT/targets/$target/k3s/traefik/traefik.yaml"
	if [ -f "$traefik_yaml" ]; then
		echo "=== K3s: $target ==="
		local vc
		vc="$(python3 - "$traefik_yaml" <<'PYEOF'
import yaml, sys
try:
    docs = list(yaml.safe_load_all(open(sys.argv[1])))
    for d in docs:
        if isinstance(d, dict) and d.get('kind') == 'HelmChartConfig':
            sys.stdout.write(d.get('spec',{}).get('valuesContent',''))
            break
except: pass
PYEOF
)"
		if [ -n "$vc" ]; then
			while IFS= read -r l; do
				[ -z "$l" ] && continue
				local purl="$(echo "$l" | awk -F= '{print $NF}')"
				local pname="$(echo "$l" | awk -F. '{print $3}')"
				local pver="$(echo "$vc" | grep -o "\.plugins\.$pname\.version=[^\"]*" | awk -F= '{print $NF}')"
				local result
				result="$(_update_plugin_version "$purl" "$pname" "$pver")"
				local newver
				newver="$(echo "$result" | grep "^$pname:" | cut -d: -f4)"
				if [ -n "$newver" ]; then
					# Rewrite version inside valuesContent block
					local tmp
					tmp="$(mktemp)"
					trap "rm -f '$tmp'" EXIT
					printf '{"file":"%s","old":"%s","new":"%s"}' "$traefik_yaml" "$pname" "$newver" | python3 -c "
import json, re, sys
data = json.load(sys.stdin)
with open(data['file']) as f:
    content = f.read()
new_content = re.sub(
    r'\.plugins\.' + re.escape(data['old']) + r'\.version=\S+',
    '.plugins.' + data['old'] + '.version=' + data['new'],
    content
)
with open('$tmp', 'w') as f:
    f.write(new_content)
"
					mv "$tmp" "$traefik_yaml"
					trap - EXIT
					echo "  Updated $pname → $newver (restart Traefik to apply)"
				fi
			done < <(echo "$vc" | grep -o '\.plugins\..*\.modulename=[^"]*')
		fi
	fi
}
