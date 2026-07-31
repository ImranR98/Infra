#!/bin/bash
# lib/k3s.sh — K3s installation, config, and cluster management

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

configure_k3s_sysctl() {
    local conf="/etc/sysctl.d/90-k3s.conf"
    if [ ! -f "$conf" ]; then
        cat > "$conf" <<SYSEOF
# K3s node tuning — automatically configured by Infra
fs.inotify.max_user_watches = 6000000
fs.inotify.max_user_instances = 512
user.max_user_namespaces = 28633
SYSEOF
    fi
    sysctl --system >/dev/null 2>&1 || sysctl -p "$conf" >/dev/null 2>&1 || true
    echo "Kernel parameters configured ($conf)."
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
  - "hostpath-extra-storage=true"
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

wait_for_crds() {
    local timeout_secs="${1:-300}"
    local max_tries=$(( timeout_secs / 15 ))
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
