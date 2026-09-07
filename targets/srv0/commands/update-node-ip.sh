#!/bin/bash
# DESC: Update K3s node IP after a network change
set -euo pipefail

source "$INFRA_ROOT/lib/common.sh"

SU="$(get_sudo_cmd)"

force=false
ip_arg=""
while [ $# -gt 0 ]; do
    case "$1" in
        force|--force|-f) force=true ;;
        --ip)
            if [ $# -lt 2 ]; then
                echo "Error: --ip requires an IPv4 address" >&2
                exit 1
            fi
            ip_arg="$2"
            shift
            ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            exit 1
            ;;
    esac
    shift
done

if [ -n "$ip_arg" ]; then
    new_ip="$ip_arg"
else
    new_ip=$(get_node_ip | head -1) || { echo "Error: could not detect primary IP" >&2; exit 1; }
fi
if [[ ! "$new_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo "Error: '$new_ip' is not a valid IPv4 address" >&2
    exit 1
fi

current_node_ip=$(grep -hPo '^\s*node-ip: \K.*' /etc/rancher/k3s/config.yaml /etc/rancher/k3s/config.yaml.d/*.yaml 2>/dev/null | head -1 || echo "")

if [ "$force" != true ] && [ "$current_node_ip" = "$new_ip" ]; then
    echo "Node IP matches ($new_ip). Nothing to do."
    exit 0
elif [ -n "$current_node_ip" ]; then
    echo "Updating K3s node IP: $current_node_ip → $new_ip"
else
    echo "No previous node-ip config found; setting IP to $new_ip."
fi

$SU bash -c 'mkdir -p "$1"' _ "/etc/rancher/k3s/config.yaml.d"

for f in /etc/rancher/k3s/config.yaml /etc/rancher/k3s/config.yaml.d/*.yaml; do
    [ -f "$f" ] || continue
    $SU sed -i "s/^\([[:space:]]*\)node-ip: .*/\1node-ip: ${new_ip}/" "$f"
done

printf 'node-ip: %s\n' "$new_ip" | $SU bash -c 'tee "$1" >/dev/null' _ "/etc/rancher/k3s/config.yaml.d/50-node-ip.yaml"

$SU bash -c 'systemctl daemon-reload'

_etcd_reachable() {
    curl -sk --connect-timeout 2 https://127.0.0.1:2379/version >/dev/null 2>&1
}

_etcdctl() {
    $SU etcdctl \
        --endpoints=https://127.0.0.1:2379 \
        --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
        --cert=/var/lib/rancher/k3s/server/tls/etcd/server-client.crt \
        --key=/var/lib/rancher/k3s/server/tls/etcd/server-client.key \
        "$@"
}

_ensure_etcdctl() {
    if command -v etcdctl >/dev/null 2>&1; then return 0; fi
    if ! _etcd_reachable; then return 1; fi
    echo "Installing etcdctl..."
    local etcd_ver
    etcd_ver=$(curl -sk https://127.0.0.1:2379/version 2>/dev/null | grep -oP '"etcdserver":"\K[^"]+' | sed 's/^v//; s/+.*//; s/-k3s.*//' | head -1 || true)
    [ -n "$etcd_ver" ] || etcd_ver="3.6.3"
    if ! curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 \
        "https://github.com/etcd-io/etcd/releases/download/v${etcd_ver}/etcd-v${etcd_ver}-linux-amd64.tar.gz" \
        | $SU tar xz -C /usr/local/bin --strip-components=1 "etcd-v${etcd_ver}-linux-amd64/etcdctl"; then
        echo "Warning: could not install etcdctl." >&2
        return 1
    fi
    return 0
}

_etcd_update_members() {
    local member_ids member_id
    member_ids=$(_etcdctl member list 2>/dev/null | awk -F, -v n="$(hostname)-" '$3 ~ "^"n {print $1}' || true)
    for member_id in $member_ids; do
        if _etcdctl member update "$member_id" --peer-urls="https://${new_ip}:2380" >/dev/null 2>&1; then
            echo "Updated etcd member $member_id peer URL to https://${new_ip}:2380"
        else
            echo "Warning: failed to update etcd member $member_id peer URL." >&2
        fi
    done
}

if [ -d /var/lib/rancher/k3s/server/db/etcd ]; then
    # The etcd member peer URL must be updated BEFORE k3s restarts. The k3s
    # systemd unit is Type=notify with no start timeout, and at startup k3s
    # retry-loops on "this server is not a member of the etcd cluster" while
    # the member's peer URL differs from the configured node-ip. A synchronous
    # restart deadlocks: systemctl waits for READY=1, k3s waits for this update.
    if _ensure_etcdctl; then
        if _etcd_reachable; then
            echo "Updating etcd member peer URL before k3s restart..."
            _etcd_update_members
        else
            echo "Note: etcd not reachable yet; member update will run after the k3s restart."
        fi
    else
        echo "Note: could not install etcdctl before restart; will retry after the k3s restart."
    fi
fi

if systemctl is-active --quiet k3s.service 2>/dev/null; then
    # --no-block: never wait on the start job (see deadlock note above).
    $SU bash -c 'systemctl restart --no-block k3s.service'
elif systemctl is-active --quiet k3s-agent.service 2>/dev/null; then
    $SU bash -c 'systemctl restart --no-block k3s-agent.service'
else
    echo "Warning: neither k3s.service nor k3s-agent.service is active; no restart performed." >&2
fi

if [ -d /var/lib/rancher/k3s/server/db/etcd ]; then
    echo "Embedded etcd detected; waiting for etcd to be reachable..."
    etcd_up=false
    for i in $(seq 1 12); do
        if _etcd_reachable; then
            etcd_up=true
            break
        fi
        sleep 5
    done

    if [ "$etcd_up" != true ]; then
        echo "Warning: etcd did not become reachable within 60s; skipping etcd member update." >&2
    elif _ensure_etcdctl; then
        # Idempotent safety net: breaks a startup retry-loop if the pre-restart
        # update was skipped (e.g. k3s was down when this script started).
        _etcd_update_members
    fi
fi

echo "Waiting for cluster to be ready..."
wait_for_k3s_cluster

node_name=$(kubectl get node "$(hostname)" -o jsonpath='{.metadata.name}' 2>/dev/null)
if [ -n "$node_name" ]; then
    kubectl annotate node "$node_name" flannel.alpha.coreos.com/public-ip="$new_ip" --overwrite 2>/dev/null || true

    if command -v jq >/dev/null 2>&1; then
        if kubectl get node "$node_name" -o json 2>/dev/null | jq --arg ip "$new_ip" '{status: {addresses: (.status.addresses | map(if .type == "InternalIP" then .address = $ip else . end))}}' > /tmp/k3s-node-status-patch.json 2>/dev/null; then
            kubectl patch node "$node_name" --subresource=status --type=merge -p "$(cat /tmp/k3s-node-status-patch.json)" 2>/dev/null || true
        fi
        rm -f /tmp/k3s-node-status-patch.json
    fi
fi

echo "Done. K3s node IP updated to $new_ip."
