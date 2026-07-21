#!/bin/bash
[[ "${ATLAS_LIB_LOADED:-}" = true ]] && return 0
ATLAS_LIB_LOADED=true

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
: ${ATLAS_ROOT:="$(cd "$_lib_dir/.." >/dev/null 2>&1 && pwd)"}

# ====== packages ======

get_sudo_cmd() {
    local has_sudo=false has_run0=false
    command -v sudo  >/dev/null 2>&1 && has_sudo=true
    command -v run0  >/dev/null 2>&1 && has_run0=true

    if $has_run0 && $has_sudo; then
        ${ATLAS_INTERACTIVE:-false} && echo "sudo" || echo "run0"
    elif $has_run0; then
        echo "run0"
    else
        echo "sudo"
    fi
}

detect_pkgmgr() {
    if command -v apt-get >/dev/null 2>&1; then echo "apt"
    elif command -v rpm-ostree >/dev/null 2>&1; then echo "rpm-ostree"
    elif command -v dnf >/dev/null 2>&1; then echo "dnf"
    else echo "unknown"
    fi
}

install_pkgs() {
    local su="$1"; local pkgmgr="$2"; shift 2
    local cmd_str
    # Build a shell-escaped argument string safe for embedding in bash -c
    printf -v cmd_str '%q ' "$@"
    case "$pkgmgr" in
        apt) $su bash -c "apt-get install -y $cmd_str" || return 1 ;;
        dnf) $su bash -c "dnf install -y $cmd_str" || return 1 ;;
        rpm-ostree) rpm-ostree install --apply-live --assumeyes $cmd_str || return 1 ;;
        *) return 1 ;;
    esac
}

ensure_docker_repo() {
    local su="$1"; local pkgmgr="$2"
    case "$pkgmgr" in
        apt)
            install_pkgs "$su" "$pkgmgr" curl gnupg
            $su bash -c 'install -m 0755 -d /etc/apt/keyrings'
            os_id=$(. /etc/os-release && echo "${ID:-ubuntu}")
            os_codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
            case "$os_id" in
                debian) docker_distro="debian" ;;
                *)      docker_distro="ubuntu" ;;
            esac
            curl -fsSL "https://download.docker.com/linux/$docker_distro/gpg" | $su bash -c 'gpg --dearmor -o /etc/apt/keyrings/docker.gpg'
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$docker_distro $os_codename stable" | $su bash -c 'tee /etc/apt/sources.list.d/docker.list >/dev/null'
            $su bash -c "$pkgmgr update -qq"
            ;;
        dnf)
            $su bash -c "$pkgmgr install -y dnf-plugins-core"
            $su bash -c "$pkgmgr config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo"
            ;;
        rpm-ostree)
            rpm-ostree refresh-md
            ;;
    esac
}

# ====== networking ======

get_node_ip() {
    local iface
    iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    [ -n "$iface" ] || return 1
    ip -4 addr show "$iface" | grep -oP 'inet \K[\d.]+'
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

    for v in MY_UID TARGET COMPOSE_STATE_DIR COMPOSE_STATE_BACKUP_DIR K3S_STATE_DIR PVC_BACKUP_DIR DOCKER_GID PROXY_IP; do
        case " $vars " in *" $v "*) ;; *) vars="$vars $v" ;; esac
    done

    echo "$vars" | tr ' ' '\n' | sort -u | sed 's/^/$/' | tr '\n' ' '
}

# Populate ENVSUBST_VARS from the VARS file if not already set, so envsubst
# only substitutes variables that are actually defined.
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
    # ${PROXY_HOST:-} guarded because not all targets define PROXY_HOST
    # (e.g. vps0 is itself the proxy), and set -u would fatal.
    if [ -n "${PROXY_HOST:-}" ]; then
        PROXY_IP="$(getent hosts "$PROXY_HOST" 2>/dev/null | awk '{print $1; exit}')"
        if [ -z "$PROXY_IP" ]; then
            echo "Warning: could not resolve PROXY_HOST='$PROXY_HOST' to an IP address" >&2
        else
            export PROXY_IP
        fi
    fi
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
                # Authelia expects users_database.yml keys indented 2 spaces
                # deeper than the $AUTHELIA_USERS_DATABASE block scalar in VARS.
                printf '%s\n' "$AUTHELIA_USERS_DATABASE" | awk 'NR==1{print} NR>1&&/./{print "  " $0} NR>1&&!/./{print}' > "$COMPOSE_STATE_DIR/authelia/config/users_database.yml" ;;
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

    EXPECTED_K3S_SCRIPT_SHA256=$(curl -fsSL --connect-timeout 10 --max-time 30 https://github.com/k3s-io/k3s/raw/main/install.sh 2>/dev/null | sha256sum | cut -d' ' -f1)
    DOWNLOADED_SHA256=$(sha256sum "$K3S_SCRIPT" | cut -d' ' -f1)
    if [ -z "$EXPECTED_K3S_SCRIPT_SHA256" ]; then
        echo "Error: could not verify K3s install script (GitHub unreachable)." >&2
        exit 1
    elif [ "$EXPECTED_K3S_SCRIPT_SHA256" != "$DOWNLOADED_SHA256" ]; then
        echo "Error: K3s install script checksum mismatch." >&2
        echo "  Expected: $EXPECTED_K3S_SCRIPT_SHA256" >&2
        echo "  Got:      $DOWNLOADED_SHA256" >&2
        rm -f "$K3S_SCRIPT"
        exit 1
    fi
    chmod +x "$K3S_SCRIPT"
}

configure_k3s_firewall() {
    # Check for firewalld (RHEL/Fedora family)
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16 2>/dev/null || true  # pod network CIDR
        firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16 2>/dev/null || true  # service CIDR
        firewall-cmd --permanent --add-port=8472/udp 2>/dev/null || true   # Flannel VXLAN overlay
        firewall-cmd --permanent --add-port=51820/udp 2>/dev/null || true  # Flannel WireGuard backend
        firewall-cmd --permanent --add-port=6443/tcp 2>/dev/null || true   # K3s API server
        firewall-cmd --permanent --add-port=10250/tcp 2>/dev/null || true  # kubelet API
        firewall-cmd --permanent --add-port=2379/tcp 2>/dev/null || true   # etcd client
        firewall-cmd --permanent --add-port=2380/tcp 2>/dev/null || true   # etcd peer
        firewall-cmd --permanent --add-port=443/tcp 2>/dev/null || true    # HTTPS ingress
        firewall-cmd --reload
        echo "Firewall configured (firewalld)."
    # Check for ufw (Ubuntu/Debian family)
    elif command -v ufw >/dev/null 2>&1; then
        ufw allow from 10.42.0.0/16 2>/dev/null || true   # pod network CIDR
        ufw allow from 10.43.0.0/16 2>/dev/null || true   # service CIDR
        ufw allow 8472/udp 2>/dev/null || true            # Flannel VXLAN overlay
        ufw allow 51820/udp 2>/dev/null || true           # Flannel WireGuard backend
        ufw allow 6443/tcp 2>/dev/null || true            # K3s API server
        ufw allow 10250/tcp 2>/dev/null || true           # kubelet API
        ufw allow 2379/tcp 2>/dev/null || true            # etcd client
        ufw allow 2380/tcp 2>/dev/null || true            # etcd peer
        ufw allow 443/tcp 2>/dev/null || true             # HTTPS ingress
        echo "Firewall configured (ufw)."
    else
        echo "Warning: neither firewall-cmd nor ufw found. Skipping firewall configuration."
        echo "If using a different firewall, ensure:"
        echo "  - Pod CIDR 10.42.0.0/16 and Service CIDR 10.43.0.0/16 are trusted"
        echo "  - Ports 8472/udp, 51820/udp, 6443/tcp, 10250/tcp, 2379-2380/tcp, 443/tcp are open"
    fi
}

wait_for_k3s_cluster() {
    local timeout_secs="${1:-150}"
    local max_tries=$(( timeout_secs / 5 ))
    for i in $(seq 1 "$max_tries"); do
        if kubectl get nodes >/dev/null 2>&1; then
            echo "Cluster ready."
            return 0
        fi
        echo "Waiting... ($i/$max_tries)"
        sleep 5
    done
    echo "Error: Could not connect to Kubernetes cluster after ${timeout_secs} seconds." >&2
    return 1
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
        echo "Error: $(basename "$file") references '\$$v' but it's not defined in VARS template"
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

# Echo variable-reference errors for a file and increment the error counter
# by the number of errors found.  The caller must 'local errors=0' first;
# bash makes local variables visible to called functions.
_count_ref_errors() {
    local known_vars="$1" file="$2"
    local ref_errors; ref_errors=$(_check_var_refs "$known_vars" "$file")
    if [ -n "$ref_errors" ]; then
        echo "$ref_errors"
        errors=$((errors + $(echo "$ref_errors" | wc -l)))
    fi
}

_validate_k3s() {
    local target="$1" comp_dir="$ATLAS_ROOT/targets/$target/k3s" errors=0

    local known_vars; known_vars=$(_build_known_vars "$target" "MY_UID
TARGET
COMPOSE_STATE_DIR
COMPOSE_STATE_BACKUP_DIR
K3S_STATE_DIR
PVC_BACKUP_DIR
NS
PV
PVC
VOLUMES")

    for comp_dir in "$comp_dir"/*/; do
        local comp; comp=$(basename "$comp_dir")
        local kfile="$comp_dir/kustomization.yaml"

        [ -f "$kfile" ] || { echo "Error: $comp missing kustomization.yaml"; errors=$((errors + 1)); continue; }

        if command -v kubectl >/dev/null 2>&1; then
            kubectl kustomize "$comp_dir" >/dev/null || { echo "Error: $comp kustomize build failed"; errors=$((errors + 1)); }
        fi

        local yaml_files=()
        for yf in "$comp_dir"/*.yaml "$comp_dir"/*.yml; do if [ -f "$yf" ]; then yaml_files+=("$yf"); fi; done
        for yf in "${yaml_files[@]}"; do
            _count_ref_errors "$known_vars" "$yf"
        done
    done

    echo ""
    echo "K3s validation: $errors errors"
    return $(( errors > 0 ? 1 : 0 ))
}

_validate_compose() {
    local target="$1" errors=0

    for f in "$ATLAS_ROOT/targets/$target/compose/compose.yaml"; do
        [ -f "$f" ] || continue
        if [[ "$f" =~ \.(yaml|yml)$ ]]; then
            if ! yq eval '.' "$f" >/dev/null 2>&1; then
                echo "Error: $(basename "$f") has invalid YAML syntax"
                errors=$((errors + 1))
            fi
        fi
    done
    while IFS= read -r -d '' f; do
        [[ "$f" =~ \.(yaml|yml)$ ]] || continue
        if ! yq eval '.' "$f" >/dev/null 2>&1; then
            echo "Error: $(basename "$f") has invalid YAML syntax"
            errors=$((errors + 1))
        fi
    done < <(find "$ATLAS_ROOT/targets/$target/compose/templates" -type f -print0 2>/dev/null)

    local known_vars; known_vars=$(_build_known_vars "$target" "MY_UID
TARGET
DOCKER_GID
COMPOSE_STATE_DIR")

    local compose_files=("$ATLAS_ROOT/targets/$target/compose/compose.yaml")
    for f in "$ATLAS_ROOT/targets/$target/compose/templates"/*; do if [ -f "$f" ]; then compose_files+=("$f"); fi; done
    for f in "${compose_files[@]}"; do
        _count_ref_errors "$known_vars" "$f"
    done

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        if [ -f "$COMPOSE_STATE_DIR/compose.yaml" ]; then
            docker compose -f "$COMPOSE_STATE_DIR/compose.yaml" config --dry-run >/dev/null || { echo "Error: docker compose config validation failed"; errors=$((errors + 1)); }
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

    # Traefik Host rules use backtick-delimited syntax:  Host(`example.com`)
    # \x60 is the backtick character (`) in hex — simpler than escaping it.
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

# ====== retry ======

# retry: runs a shell command (passed as remaining arguments) up to TRIES times,
# sleeping DELAY seconds between attempts.  Uses eval to support pipelines and
# redirections, so callers must pass only trusted, hard-coded command strings.
retry() {
    local tries="${1:-30}"
    local delay="${2:-5}"
    shift 2
    for _ in $(seq 1 "$tries"); do
        eval "$*" 2>/dev/null && return 0
        sleep "$delay"
    done
    return 1
}

# ====== k3s config ======

write_k3s_config() {
    local role="${1:-server}"
    local node_ip="${2:-}"
    local config_file="$3"
    local cluster_init="${4:-false}"

    if [ "$role" = "server" ]; then
        cat > "$config_file" <<K3SEOF
selinux: true
write-kubeconfig-mode: "0640"
$([ "$cluster_init" = true ] && echo 'cluster-init: true')
flannel-backend: wireguard-native
node-ip: $node_ip
flannel-iface-regex: "^(eth|ens|enp|eno|enx|wlan|wlp|wlo|bond|ib)"
node-label:
  - "hostpath-main=true"
  - "external-exposed=true"
K3SEOF
    else
        cat > "$config_file" <<K3SEOF
selinux: true
flannel-backend: wireguard-native
node-ip: $node_ip
flannel-iface-regex: "^(eth|ens|enp|eno|enx|wlan|wlp|wlo|bond|ib)"
K3SEOF
    fi
}

# ====== wait ======

wait_for_crds() {
    local timeout_secs="${1:-300}"
    local max_tries=$(( timeout_secs / 15 ))  # 10s kubectl call + 5s sleep per iteration
    shift

    local all_ok=true
    for crd in "$@"; do
        local crd_ok=false
        for _ in $(seq 1 "$max_tries"); do
            kubectl wait --for condition=established "crd/$crd" --timeout=10s 2>/dev/null && { crd_ok=true; break; }
            sleep 5
        done
        if [ "$crd_ok" = false ]; then
            echo "Error: CRD $crd not established after ${timeout_secs}s" >&2
            all_ok=false
        fi
    done
    $all_ok
}
