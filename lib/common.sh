#!/bin/bash
# Common library for Atlas — sourced by atlas.sh, apply_k3s_component.sh,
# validate.sh, and k3s-install.sh.

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
: ${VARS_ROOT:="$(cd "$_lib_dir/.." >/dev/null 2>&1 && pwd)"}

# ---- Package manager helpers ----

get_sudo_cmd() {
	if command -v run0 &>/dev/null; then echo "run0"; else echo "sudo"; fi
}

detect_pkgmgr() {
	if command -v apt-get &>/dev/null; then echo "apt"
	elif command -v rpm-ostree &>/dev/null; then echo "rpm-ostree"
	elif command -v dnf &>/dev/null; then echo "dnf"
	else echo "unknown"
	fi
}

install_pkgs() {
	local su="$1"; local pkgmgr="$2"; shift 2
	case "$pkgmgr" in
		apt) $su apt-get install -y "$@" || return 1 ;;
		dnf) $su dnf install -y "$@" || return 1 ;;
		rpm-ostree) $su rpm-ostree install --apply-live --assumeyes "$@" || return 1 ;;
		*) return 1 ;;
	esac
}

ensure_docker_repo() {
	local su="$1"; local pkgmgr="$2"
	case "$pkgmgr" in
		apt)
			install_pkgs "$su" "$pkgmgr" curl gnupg
			$su install -m 0755 -d /etc/apt/keyrings
			os_id=$(. /etc/os-release && echo "${ID:-ubuntu}")
			os_codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
			case "$os_id" in
				debian) docker_distro="debian" ;;
				*)      docker_distro="ubuntu" ;;
			esac
			curl -fsSL "https://download.docker.com/linux/$docker_distro/gpg" | $su gpg --dearmor -o /etc/apt/keyrings/docker.gpg
			echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$docker_distro $os_codename stable" | $su tee /etc/apt/sources.list.d/docker.list >/dev/null
			$su "$pkgmgr" update -qq
			;;
		dnf)
			$su "$pkgmgr" install -y dnf-plugins-core
			$su "$pkgmgr" config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
			;;
		rpm-ostree)
			$su rpm-ostree refresh-md
			;;
	esac
}

# ---- VARS file handling ----

source_env() {
	local target="${TARGET:-${1:-}}"
	if [ -z "$target" ]; then
		echo "Error: TARGET must be set before calling source_env" >&2
		exit 1
	fi

	local vars_file
	if [ -f "$VARS_ROOT/VARS.${target}.sh" ]; then
		vars_file="$VARS_ROOT/VARS.${target}.sh"
	elif [ -f "$VARS_ROOT/VARS.sh" ]; then
		vars_file="$VARS_ROOT/VARS.sh"
	else
		echo "Error: neither VARS.${target}.sh nor VARS.sh found at $VARS_ROOT" >&2
		exit 1
	fi

	while IFS= read -r var; do
		if ! grep -q "^export $var=" "$vars_file"; then
			echo "Error: $vars_file is missing required variable: $var" >&2
			exit 1
		fi
	done < <(grep -hEo '^export [^=]+' "$VARS_ROOT/vars/VARS.${target}.sh" 2>/dev/null | sed 's/^export //' | sort -u)

	source "$vars_file"

	if [ "$(id -u)" -eq 0 ]; then
		export MY_UID=1000
	else
		export MY_UID=$(id -u)
	fi

	export TARGET="$target"
}

# ---- Envsubst variable collection ----
# Single function that scans VARS exports, compose templates, AND k3s
# component YAMLs for $VAR / ${VAR} references.  Always includes MY_UID
# and TARGET.  Returns a space-separated list of $VAR strings suitable
# for envsubst.

get_envsubst_vars() {
	local vars=""

	# VARS file exports
	local vars_file=""
	if [ -f "$VARS_ROOT/VARS.$TARGET.sh" ]; then
		vars_file="$VARS_ROOT/VARS.$TARGET.sh"
	elif [ -f "$VARS_ROOT/VARS.sh" ]; then
		vars_file="$VARS_ROOT/VARS.sh"
	fi
	if [ -n "$vars_file" ]; then
		vars="$vars $(grep -oP 'export \K[A-Z_][A-Z_0-9]*' "$vars_file" | tr '\n' ' ')"
	fi

	# Compose template references
	if [ -f "$VARS_ROOT/compose/$TARGET.compose.yaml" ]; then
		vars="$vars $(grep -hEo '\$[A-Z_][A-Z_0-9]*|\$\{[A-Z_][A-Z_0-9]*\}' "$VARS_ROOT/compose/$TARGET.compose.yaml" 2>/dev/null | sed 's/[{}]//g' | tr '\n' ' ')"
	fi
	for f in "$VARS_ROOT/templates/$TARGET"/*.yaml "$VARS_ROOT/templates/$TARGET"/*.json "$VARS_ROOT/templates/$TARGET"/*.txt "$VARS_ROOT/templates/$TARGET"/*.toml; do
		[ -f "$f" ] || continue
		vars="$vars $(grep -hEo '\$[A-Z_][A-Z_0-9]*|\$\{[A-Z_][A-Z_0-9]*\}' "$f" 2>/dev/null | sed 's/[{}]//g' | tr '\n' ' ')"
	done

	# K3s component YAML references
	if [ -d "$VARS_ROOT/k3s/$TARGET" ]; then
		vars="$vars $(grep -rhoE '\$[A-Z_][A-Z_0-9]*|\$\{[A-Z_][A-Z_0-9]*\}' "$VARS_ROOT/k3s/$TARGET" --include='*.yaml' 2>/dev/null | sed 's/[${}]//g' | tr '\n' ' ')"
	fi

	# Always include
	for v in MY_UID TARGET; do
		case " $vars " in *" $v "*) ;; *) vars="$vars $v" ;; esac
	done

	echo "$vars" | tr ' ' '\n' | sort -u | sed 's/^/$/' | tr '\n' ' '
}

# ---- Domain listing ----

list_domains() {
	local target="${1:-$TARGET}"

	# K3s: grep IngressRoute Host() from component YAMLs
	if [ -d "$VARS_ROOT/k3s/$target" ]; then
		grep -rohP "Host\(\x60[^\x60]+\x60\)" --include="*.yaml" "$VARS_ROOT/k3s/$target" | \
			sed "s/.*\x60\([^\x60]*\)\x60.*/\1/" | \
			grep -v "\.localhost" | \
			envsubst "$(get_envsubst_vars)" | \
			sort -u
	fi

	# Compose: grep Host() from Traefik dynamic config in compose file
	if [ -f "$VARS_ROOT/compose/${target}.compose.yaml" ]; then
		sed -n 's/.*Host(`\([^`]*\)`).*/\1/p' "$VARS_ROOT/compose/${target}.compose.yaml" | \
			sort -u | \
			envsubst "$(get_envsubst_vars)"
	fi
}

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
		latest="$(curl -s "https://api.github.com/repos/$(echo "$url" | sed 's|github\.com/||')/releases/latest" | jq -r '.tag_name')"
		if [ "$current" != "$latest" ]; then
			echo "  $name: $current → $latest"
			echo "$name:$url:$current:$latest"
		else
			echo "  $name already latest ($latest)"
		fi
	}

	# Compose path
	local compose_file="$VARS_ROOT/compose/${target}.compose.yaml"
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
	local traefik_yaml="$VARS_ROOT/k3s/$target/traefik/traefik.yaml"
	if [ -f "$traefik_yaml" ]; then
		echo "=== K3s: $target ==="
		local vc
		vc="$(python3 -c "
import yaml, sys
try:
    docs = list(yaml.safe_load_all(open('$traefik_yaml')))
    for d in docs:
        if isinstance(d, dict) and d.get('kind') == 'HelmChartConfig':
            sys.stdout.write(d.get('spec',{}).get('valuesContent',''))
            break
except: pass
" 2>/dev/null)"
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
					python3 -c "
import re
with open('$traefik_yaml') as f: content = f.read()
new_content = re.sub(
    r'\.plugins\.$pname\.version=' + re.escape('$pver'),
    '.plugins.$pname.version=$newver', content
)
with open('$tmp', 'w') as f: f.write(new_content)
"
					mv "$tmp" "$traefik_yaml"
					echo "  Updated $pname → $newver (restart Traefik to apply)"
				fi
			done < <(echo "$vc" | grep -o '\.plugins\..*\.modulename=[^"]*')
		fi
	fi
}

# ---- Old images (Docker only; K3s uses containerd with kubelet GC) ----

old_images() {
	local current_time
	current_time=$(date +%s)
	docker images --no-trunc --format "{{.Repository}}:{{.Tag}}\t{{.CreatedAt}}" | \
		while IFS=$'\t' read -r image created; do
			created_time=$(date -d "$created" +%s 2>/dev/null) || continue
			days=$(( (current_time - created_time) / 86400 ))
			if [ "$days" -gt 60 ]; then
				printf "%-50s %3d days\n" "$image" "$days"
			fi
		done | sort -k2 -n
}

# ---- Validate (both stacks) ----

validate() {
	local target="${1:-$TARGET}"
	local k3s_ok=true compose_ok=true

	if [ -d "$VARS_ROOT/k3s/$target" ]; then
		_validate_k3s "$target" || k3s_ok=false
	fi
	if [ -f "$VARS_ROOT/compose/${target}.compose.yaml" ]; then
		_validate_compose "$target" || compose_ok=false
	fi

	echo ""
	echo "K3s:     $( $k3s_ok && echo "OK" || echo "issues found" )"
	echo "Compose: $( $compose_ok && echo "OK" || echo "issues found" )"
}

_validate_k3s() {
	local target="$1"
	local comp_dir="$VARS_ROOT/k3s/$target"
	local errors=0 warnings=0

	# Gather required vars from VARS template
	local known_vars="MY_UID
TARGET
COMPOSE_STATE_DIR
COMPOSE_STATE_BACKUP_DIR
LONGHORN_BACKUP_DIR
NS
PV
PVC
VOLUMES"
	local template_file="$VARS_ROOT/vars/VARS.$target.sh"
	if [ -f "$template_file" ]; then
		while IFS= read -r v; do
			known_vars+="
$v"
		done < <(grep -oP 'export \K[A-Z_][A-Z_0-9]*' "$template_file" 2>/dev/null || true)
	fi

	for comp_dir in "$comp_dir"/*/; do
		local comp; comp=$(basename "$comp_dir")
		local kfile="$comp_dir/kustomization.yaml"

		if [ ! -f "$kfile" ]; then
			echo "ERROR: $comp missing kustomization.yaml"
			errors=$((errors + 1))
			continue
		fi

		# Resources listed exist
		while IFS= read -r resource; do
			[ -z "$resource" ] && continue
			if [ ! -f "$comp_dir/$resource" ] && [ ! -d "$comp_dir/$resource" ]; then
				echo "ERROR: $comp/$resource listed in kustomization.yaml but not found"
				errors=$((errors + 1))
			fi
		done < <(yq '.resources[]' "$kfile" 2>/dev/null)

		# Orphan YAMLs not listed
		for yf in "$comp_dir"*.yaml "$comp_dir"*.yml; do
			[ -f "$yf" ] || continue
			local fn; fn=$(basename "$yf")
			[ "$fn" = "kustomization.yaml" ] && continue
			[ "$fn" = "issuers.yaml" ] && continue  # applied by post.sh
			if ! grep -qF "$fn" "$kfile"; then
				echo "WARN: $comp/$fn not listed in kustomization.yaml"
				warnings=$((warnings + 1))
			fi
		done

		# Overlay kustomization check
		for overlay_dir in "$comp_dir"/overlays/*/; do
			[ -d "$overlay_dir" ] || continue
			local overlay; overlay=$(basename "$overlay_dir")
			if [ ! -f "$overlay_dir/kustomization.yaml" ]; then
				echo "ERROR: $comp overlay '$overlay' missing kustomization.yaml"
				errors=$((errors + 1))
			fi
		done

		# Env var references not in known vars
		for yf in "$comp_dir"*.yaml "$comp_dir"*.yml; do
			[ -f "$yf" ] || continue
			while IFS= read -r var; do
				[ -z "$var" ] && continue
				if echo "$known_vars" | grep -qx "$var"; then continue; fi
				echo "WARN: $comp/$(basename "$yf") references '\$$var' but it's not defined in VARS template"
				warnings=$((warnings + 1))
			done < <(grep -v '^[[:space:]]*#' "$yf" 2>/dev/null | grep -oP '\$[A-Z_][A-Z_0-9]*|\$\{[A-Z_][A-Z_0-9]*\}' | sed 's/^\$//;s/[{}]//g' | sort -u)
		done
	done

	echo ""
	echo "K3s validation: $errors errors, $warnings warnings"
	return $(( errors > 0 ? 1 : 0 ))
}

_validate_compose() {
	local target="$1"
	local errors=0 warnings=0

	local template_file="$VARS_ROOT/vars/VARS.$target.sh"
	local known_vars="MY_UID
TARGET
DOCKER_GID
FRPC_USER
COMPOSE_STATE_DIR"
	if [ -f "$template_file" ]; then
		while IFS= read -r v; do
			known_vars+="
$v"
		done < <(grep -oP 'export \K[A-Z_][A-Z_0-9]*' "$template_file" 2>/dev/null || true)
	fi

	# Scan compose file + templates
	for f in "$VARS_ROOT/compose/${target}.compose.yaml" "$VARS_ROOT/templates/$target"/*; do
		[ -f "$f" ] || continue
		while IFS= read -r var; do
			[ -z "$var" ] && continue
			if echo "$known_vars" | grep -qx "$var"; then continue; fi
			echo "WARN: $f references '\$$var' but it's not defined in VARS template"
			warnings=$((warnings + 1))
		done < <(grep -hEo '\$[A-Z_][A-Z_0-9]*|\$\{[A-Z_][A-Z_0-9]*\}' "$f" 2>/dev/null | sed 's/^\$//;s/[{}]//g' | sort -u)
	done

	# Docker Compose dry-run
	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		if [ -f "$COMPOSE_STATE_DIR/compose.yaml" ]; then
			if ! docker compose -f "$COMPOSE_STATE_DIR/compose.yaml" config --dry-run >/dev/null 2>&1; then
				echo "ERROR: docker compose config validation failed"
				errors=$((errors + 1))
			fi
		fi
	fi

	echo ""
	echo "Compose validation: $errors errors, $warnings warnings"
	return $(( errors > 0 ? 1 : 0 ))
}
