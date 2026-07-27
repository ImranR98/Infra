#!/bin/bash
# DESC: Update K3s node IP after a network change
set -euo pipefail

source "$INFRA_ROOT/lib/common.sh"

SU="$(get_sudo_cmd)"

force=false
case "${1:-}" in
    force|--force|-f) force=true ;;  
esac

new_ip=$(get_node_ip) || { echo "Error: could not detect primary IP" >&2; exit 1; }

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
if systemctl is-active --quiet k3s.service 2>/dev/null; then
    $SU bash -c 'systemctl restart k3s.service'
fi

if [ -d /var/lib/rancher/k3s/server/db/etcd ]; then
    echo "Embedded etcd detected; waiting for etcd to be reachable..."
    for i in $(seq 1 12); do
        if curl -sk --connect-timeout 2 https://127.0.0.1:2379/version >/dev/null 2>&1; then
            break
        fi
        sleep 5
    done

    if ! command -v etcdctl >/dev/null 2>&1; then
        echo "Installing etcdctl..."
        etcd_ver=$(curl -sk https://127.0.0.1:2379/version 2>/dev/null | grep -oP '"etcdserver":"\K[^"]+' || echo "3.6.3")
        curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 \
            "https://github.com/etcd-io/etcd/releases/download/v${etcd_ver}/etcd-v${etcd_ver}-linux-amd64.tar.gz" \
            | $SU tar xz -C /usr/local/bin --strip-components=1 "etcd-v${etcd_ver}-linux-amd64/etcdctl"
    fi

    echo "Updating etcd member peer URL..."
    MEMBER_ID=$($SU etcdctl \
        --endpoints=https://127.0.0.1:2379 \
        --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
        --cert=/var/lib/rancher/k3s/server/tls/etcd/server-client.crt \
        --key=/var/lib/rancher/k3s/server/tls/etcd/server-client.key \
        member list 2>/dev/null | grep ',' | awk -F',' '{print $1}' | head -1)

    if [ -n "$MEMBER_ID" ]; then
        $SU etcdctl \
            --endpoints=https://127.0.0.1:2379 \
            --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
            --cert=/var/lib/rancher/k3s/server/tls/etcd/server-client.crt \
            --key=/var/lib/rancher/k3s/server/tls/etcd/server-client.key \
            member update "$MEMBER_ID" --peer-urls="https://${new_ip}:2380"
    fi
fi

echo "Waiting for cluster to be ready..."
wait_for_k3s_cluster

node_name=$(kubectl get node "$(hostname)" -o jsonpath='{.metadata.name}' 2>/dev/null)
if [ -n "$node_name" ]; then
    kubectl annotate node "$node_name" flannel.alpha.coreos.com/public-ip="$new_ip" --overwrite 2>/dev/null || true

    if command -v python3 >/dev/null 2>&1; then
        kubectl get node "$node_name" -o json 2>/dev/null | python3 -c "
import sys, json
node = json.load(sys.stdin)
addrs = node.get('status', {}).get('addresses', [])
for a in addrs:
    if a.get('type') == 'InternalIP':
        a['address'] = '$new_ip'
json.dump({'status': {'addresses': addrs}}, sys.stdout)
" > /tmp/k3s-node-status-patch.json 2>/dev/null && \
            kubectl patch node "$node_name" --subresource=status --type=merge -p "$(cat /tmp/k3s-node-status-patch.json)" 2>/dev/null || true
        rm -f /tmp/k3s-node-status-patch.json
    fi
fi

echo "Re-applying network policies with updated API server subnet..."
bash "$INFRA_ROOT/commands/k3s/deploy.sh" namespaces apply

echo "Done. K3s node IP updated to $new_ip."
