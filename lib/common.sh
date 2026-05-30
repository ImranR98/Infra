#!/bin/bash
[[ "${ATLAS_LIB_LOADED:-}" = true ]] && return 0
ATLAS_LIB_LOADED=true

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
: ${ATLAS_ROOT:="$(cd "$_lib_dir/.." >/dev/null 2>&1 && pwd)"}

# ====== packages ======

get_sudo_cmd() {
	local has_sudo=false has_run0=false
	command -v sudo  &>/dev/null && has_sudo=true
	command -v run0  &>/dev/null && has_run0=true

	if $has_run0 && $has_sudo; then
		${ATLAS_INTERACTIVE:-false} && echo "sudo" || echo "run0"
	elif $has_run0; then
		echo "run0"
	else
		echo "sudo"
	fi
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

# ====== vars ======

resolve_vars_file() {
	local target="${1:-${TARGET:-}}"
	if [ -f "$ATLAS_ROOT/VARS.${target}.sh" ]; then
		echo "$ATLAS_ROOT/VARS.${target}.sh"
	elif [ -f "$ATLAS_ROOT/VARS.sh" ]; then
		echo "$ATLAS_ROOT/VARS.sh"
	fi
}

get_template_export_names() {
	local target="${1:-${TARGET:-}}"
	if [ -z "$target" ]; then return 0; fi
	grep -hEo '^export [A-Z_][A-Z_0-9]*' "$ATLAS_ROOT/targets/$target/VARS.template.sh" 2>/dev/null | sed 's/^export //' | sort -u
}

source_env() {
	local target="${TARGET:-${1:-}}"
	if [ -z "$target" ]; then
		echo "Error: TARGET must be set before calling source_env" >&2
		exit 1
	fi

	local vars_file; vars_file=$(resolve_vars_file "$target")
	if [ -z "$vars_file" ]; then
		echo "Error: neither VARS.${target}.sh nor VARS.sh found at $ATLAS_ROOT" >&2
		exit 1
	fi

	while IFS= read -r var; do
		if ! grep -q "^export $var=" "$vars_file"; then
			echo "Error: $vars_file is missing required variable: $var" >&2
			exit 1
		fi
	done < <(get_template_export_names "$target")

	source "$vars_file"

	if [ "$(id -u)" -eq 0 ]; then
		export MY_UID=1000
	else
		export MY_UID=$(id -u)
	fi

	export TARGET="$target"
}

get_envsubst_vars() {
	local vars=""

	local vars_file; vars_file=$(resolve_vars_file)
	if [ -n "$vars_file" ]; then
		vars="$vars $(grep -oP 'export \K[A-Z_][A-Z_0-9]*' "$vars_file" | tr '\n' ' ')"
	fi

	for v in MY_UID TARGET COMPOSE_STATE_DIR DOCKER_GID; do
		case " $vars " in *" $v "*) ;; *) vars="$vars $v" ;; esac
	done

	echo "$vars" | tr ' ' '\n' | sort -u | sed 's/^/$/' | tr '\n' ' '
}

ensure_envsubst_vars() { export ENVSUBST_VARS="${ENVSUBST_VARS:-$(get_envsubst_vars)}"; }

# ====== compose-gen ======

render_compose_yaml() {
	ensure_envsubst_vars
	mkdir -p "$COMPOSE_STATE_DIR"
	envsubst "$ENVSUBST_VARS" < "$ATLAS_ROOT/targets/$TARGET/compose/compose.yaml" > "$COMPOSE_STATE_DIR/compose.yaml"
}

configure_compose_templates() {
	local target="$1"
	ensure_envsubst_vars
	local template_dir="$ATLAS_ROOT/targets/$target/compose/templates"
	[ -d "$template_dir" ] || return

	while IFS= read -r -d '' src; do
		local rel="${src#$template_dir/}"
		local dst="$COMPOSE_STATE_DIR/$rel"
		dst="${dst%.secret}"
		dst="${dst%.plain}"
		mkdir -p "$(dirname "$dst")"

		case "$rel" in
			*.plain) cp "$src" "$dst" ;;
			*.secret)
				envsubst "$ENVSUBST_VARS" < "$src" > "$dst"
				chmod 600 "$dst" ;;
			authelia/*)
				if [ ! -f "$dst" ]; then
					sed '/# IGNORE INITIALLY$/ s/^/# /' "$src" | envsubst "$ENVSUBST_VARS" > "$dst"
				else
					envsubst "$ENVSUBST_VARS" < "$src" > "$dst"
				fi
				printf '%s\n' "$AUTHELIA_USERS_DATABASE" > "$COMPOSE_STATE_DIR/authelia/config/users_database.yml" ;;
			traefik/*)
				[ -f "$COMPOSE_STATE_DIR/traefik/acme.json" ] || { echo '{}' > "$COMPOSE_STATE_DIR/traefik/acme.json"; chmod 600 "$COMPOSE_STATE_DIR/traefik/acme.json"; }
				envsubst "$ENVSUBST_VARS" < "$src" > "$dst" ;;
			*) envsubst "$ENVSUBST_VARS" < "$src" > "$dst" ;;
		esac
	done < <(find "$template_dir" -type f -print0)
}

# ====== k3s-common ======

download_k3s_installer() {
	K3S_SCRIPT="$(mktemp /tmp/k3s-install.XXXXXX)"
	curl -fsSL --connect-timeout 30 --max-time 120 --retry 3 https://get.k3s.io -o "$K3S_SCRIPT"

	K3S_SCRIPT_SHA256=$(curl -fsSL --connect-timeout 10 --max-time 30 https://github.com/k3s-io/k3s/raw/main/install.sh 2>/dev/null | sha256sum | cut -d' ' -f1)
	DOWNLOADED_SHA256=$(sha256sum "$K3S_SCRIPT" | cut -d' ' -f1)
	if [ -z "$K3S_SCRIPT_SHA256" ]; then
		echo "Error: could not verify K3s install script (GitHub unreachable)." >&2
		exit 1
	elif [ "$K3S_SCRIPT_SHA256" != "$DOWNLOADED_SHA256" ]; then
		echo "Error: K3s install script checksum mismatch." >&2
		echo "  Expected: $K3S_SCRIPT_SHA256" >&2
		echo "  Got:      $DOWNLOADED_SHA256" >&2
		rm -f "$K3S_SCRIPT"
		exit 1
	fi
	chmod +x "$K3S_SCRIPT"
}

configure_firewall() {
	if ! command -v firewall-cmd >/dev/null 2>&1; then
		echo "Warning: firewall-cmd not found. Skipping firewall configuration."
		echo "If using a different firewall, ensure interfaces cni0 and flannel.1 are trusted."
	else
		firewall-cmd --permanent --zone=trusted --add-interface=cni0 2>/dev/null || true
		firewall-cmd --permanent --zone=trusted --add-interface=flannel.1 2>/dev/null || true
		firewall-cmd --reload
		echo "Firewall configured. Note: VPNs may interfere with cluster networking and should run on an upstream router."
	fi
}

# ====== validate ======

_build_known_vars() {
	local target="$1"; shift
	local known="$*"
	while IFS= read -r v; do
		if [ -z "$v" ]; then continue; fi
		known+="
$v"
	done < <(get_template_export_names "$target")
	echo "$known"
}

_check_var_refs() {
	local known_vars="$1" file="$2"
	[ -f "$file" ] || return 0
	local refs; refs=$(grep -oP '\$[A-Z_][A-Z_0-9]*|\$\{[A-Z_][A-Z_0-9]*\}' "$file" 2>/dev/null | sed 's/^\${//; s/^\$//; s/}$//' | sort -u)
	if [ -z "$refs" ]; then return 0; fi
	echo "$refs" | grep -vxFf <(echo "$known_vars") | while read -r v; do
		if [ -z "$v" ]; then continue; fi
		echo "ERROR: $(basename "$file") references '\$$v' but it's not defined in VARS template"
	done
}

validate() {
	local target="${1:-$TARGET}"
	local k3s_ok=true compose_ok=true

	if [ -d "$ATLAS_ROOT/targets/$target/k3s" ]; then
		_validate_k3s "$target" || k3s_ok=false
	fi
	if [ -f "$ATLAS_ROOT/targets/$target/compose/compose.yaml" ]; then
		_validate_compose "$target" || compose_ok=false
	fi

	echo ""
	echo "K3s:     $( $k3s_ok && echo "OK" || echo "issues found" )"
	echo "Compose: $( $compose_ok && echo "OK" || echo "issues found" )"
}

_validate_k3s() {
	local target="$1" comp_dir="$ATLAS_ROOT/targets/$target/k3s" errors=0

	local known_vars; known_vars=$(_build_known_vars "$target" "MY_UID
TARGET
COMPOSE_STATE_DIR
COMPOSE_STATE_BACKUP_DIR
LONGHORN_BACKUP_DIR
K8S_API_SERVER_IP
K8S_API_SERVER_SUBNET
NS
PV
PVC
VOLUMES")

	for comp_dir in "$comp_dir"/*/; do
		local comp; comp=$(basename "$comp_dir")
		local kfile="$comp_dir/kustomization.yaml"

		[ -f "$kfile" ] || { echo "ERROR: $comp missing kustomization.yaml"; errors=$((errors + 1)); continue; }

		if command -v kubectl >/dev/null 2>&1; then
			kubectl kustomize "$comp_dir" >/dev/null || { echo "ERROR: $comp kustomize build failed"; errors=$((errors + 1)); }
		fi

		local yaml_files=()
		for yf in "$comp_dir"/*.yaml "$comp_dir"/*.yml; do if [ -f "$yf" ]; then yaml_files+=("$yf"); fi; done
		for yf in "${yaml_files[@]}"; do
			local ref_errors; ref_errors=$(_check_var_refs "$known_vars" "$yf")
			if [ -n "$ref_errors" ]; then
				echo "$ref_errors"
				errors=$((errors + $(echo "$ref_errors" | wc -l)))
			fi
		done
	done

	echo ""
	echo "K3s validation: $errors errors"
	return $(( errors > 0 ? 1 : 0 ))
}

_validate_compose() {
	local target="$1" errors=0

	for f in "$ATLAS_ROOT/targets/$target/compose/compose.yaml" "$ATLAS_ROOT/targets/$target/compose/templates"/*; do
		[ -f "$f" ] || continue
		if [[ "$f" =~ \.(yaml|yml)$ ]]; then
			if ! yq eval '.' "$f" >/dev/null 2>&1; then
				echo "ERROR: $(basename "$f") has invalid YAML syntax"
				errors=$((errors + 1))
			fi
		fi
	done

	local known_vars; known_vars=$(_build_known_vars "$target" "MY_UID
TARGET
DOCKER_GID
COMPOSE_STATE_DIR")

	local compose_files=("$ATLAS_ROOT/targets/$target/compose/compose.yaml")
	for f in "$ATLAS_ROOT/targets/$target/compose/templates"/*; do if [ -f "$f" ]; then compose_files+=("$f"); fi; done
	for f in "${compose_files[@]}"; do
		local ref_errors; ref_errors=$(_check_var_refs "$known_vars" "$f")
		if [ -n "$ref_errors" ]; then
			echo "$ref_errors"
			errors=$((errors + $(echo "$ref_errors" | wc -l)))
		fi
	done

	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		if [ -f "$COMPOSE_STATE_DIR/compose.yaml" ]; then
			docker compose -f "$COMPOSE_STATE_DIR/compose.yaml" config --dry-run >/dev/null || { echo "ERROR: docker compose config validation failed"; errors=$((errors + 1)); }
		fi
	fi

	echo ""
	echo "Compose validation: $errors errors"
	return $(( errors > 0 ? 1 : 0 ))
}

# ====== domains ======

list_domains() {
	local target="${1:-$TARGET}"
	local sd="${SERVICES_DOMAIN:-}"
	if [ -z "$sd" ]; then sd='$SERVICES_DOMAIN'; fi

	_extract_hosts() {
		grep -rohP "Host\(\x60[^\x60]+\x60\)" "$@" 2>/dev/null | \
			sed "s/.*\x60\([^\x60]*\)\x60.*/\1/" | \
			grep -v '\.localhost'
	}

	if [ -d "$ATLAS_ROOT/targets/$target/k3s" ]; then
		_extract_hosts --include='*.yaml' "$ATLAS_ROOT/targets/$target/k3s" | \
			sed "s/\\\$SERVICES_DOMAIN/${sd}/g" | \
			sort -u
	fi

	if [ -f "$ATLAS_ROOT/targets/$target/compose/compose.yaml" ]; then
		sed -n 's/.*Host(`\([^`]*\)`).*/\1/p' "$ATLAS_ROOT/targets/$target/compose/compose.yaml" | \
			sed "s/\\\$SERVICES_DOMAIN/${sd}/g" | \
			sort -u
	fi
}

# ====== wait ======

wait_for_crds() {
	local timeout_secs="${1:-300}"
	local max_tries=$(( timeout_secs / 5 ))
	shift

	for crd in "$@"; do
		for _ in $(seq 1 "$max_tries"); do
			kubectl wait --for condition=established "crd/$crd" --timeout=10s 2>/dev/null && break
			sleep 5
		done
	done
}
