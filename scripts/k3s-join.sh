#!/bin/bash
# DESC: Join a node to the K3s cluster. Run ON the control plane: reads the
# token there, streams node prep + the official installer to the joining node
# over SSH (the token travels via stdin only — never argv), waits for Ready,
# then applies labels/taint/Longhorn replica count. Prompts for sudo on both
# machines (they may differ).
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"

SU="$(get_sudo_cmd)"
kubectl_bin="$(command -v kubectl)" || { echo "Error: kubectl not found" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") <node_ip> <node_user> [options]

  --role agent|server          joining role (default: agent)
  --amdgpu auto|yes|no         AMD GPU detection (lspci, vendor 1002; default: auto)
  --scheduling-discouraged     add the PreferNoSchedule taint
  --longhorn-replicas          enable the Longhorn default disk + bump replica count

Run ON the control plane. The first SSH to the node prompts to accept the host
key — the same trust model as plain ssh.
EOF
    exit 1
}

[ $# -ge 2 ] || usage
node_ip="$1"
node_user="$2"
shift 2

k3s_role=agent
amdgpu_mode=auto
scheduling_discouraged=false
longhorn_replicas=false
while [ $# -gt 0 ]; do
    case "$1" in
        --role) k3s_role="${2:?--role needs agent|server}"; shift 2 ;;
        --amdgpu) amdgpu_mode="${2:?--amdgpu needs auto|yes|no}"; shift 2 ;;
        --scheduling-discouraged) scheduling_discouraged=true; shift ;;
        --longhorn-replicas) longhorn_replicas=true; shift ;;
        -h | --help) usage ;;
        *) echo "Error: unknown option '$1'" >&2; usage ;;
    esac
done

[[ "$node_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "Error: node_ip must be an IPv4 address" >&2; exit 1; }
[[ "$node_user" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Error: invalid node_user" >&2; exit 1; }
[[ "$k3s_role" == agent || "$k3s_role" == server ]] || { echo "Error: --role must be agent or server" >&2; exit 1; }
[[ "$amdgpu_mode" == auto || "$amdgpu_mode" == yes || "$amdgpu_mode" == no ]] || { echo "Error: --amdgpu must be auto, yes or no" >&2; exit 1; }

echo "==> Reading the K3s server token (sudo on this machine)"
token="$($SU cat /var/lib/rancher/k3s/server/token)"
server_ip="$(get_node_ip)"
[ -n "$server_ip" ] || { echo "Error: cannot determine the control plane's IP" >&2; exit 1; }

# AMD GPU detection runs on the JOINING node (lspci — vendor 1002, VGA class).
amdgpu_enabled=false
if [ "$amdgpu_mode" = yes ]; then
    amdgpu_enabled=true
elif [ "$amdgpu_mode" = auto ]; then
    if ssh -o ConnectTimeout=10 "$node_user@$node_ip" 'lspci -n 2>/dev/null | grep -qE "0300: 1002:"'; then
        amdgpu_enabled=true
    fi
fi

echo "==> Provisioning $node_ip over SSH (sudo on the node)"
remote_script="$(
    cat "$INFRA_ROOT/scripts/k3s-node-prep.sh"
    printf '\nK3S_JOIN_ROLE=%q\n' "$k3s_role"
    printf 'K3S_JOIN_TOKEN=%q\n' "$token"
    printf 'K3S_SERVER_IP=%q\n' "$server_ip"
    printf 'K3S_NODE_IP=%q\n' "$node_ip"
    cat <<'REMOTE_SCRIPT'

# ---- K3s install (the official get.k3s.io installer — runs only when k3s is
# missing, so re-provision never fights system-upgrade-controller) ----
if [ "$K3S_JOIN_ROLE" = agent ]; then
    install -d -m 755 /etc/systemd/system
    umask 077
    printf 'K3S_TOKEN=%s\n' "$K3S_JOIN_TOKEN" >/etc/systemd/system/k3s-agent.service.env
    export INSTALL_K3S_EXEC="agent --server https://$K3S_SERVER_IP:6443 --node-ip $K3S_NODE_IP"
    if ! command -v k3s >/dev/null 2>&1; then
        curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_START=true INSTALL_K3S_VERSION=stable sh -
    fi
    systemctl daemon-reload
    systemctl enable --now k3s-agent
else
    install -d -m 755 /etc/rancher/k3s
    umask 077
    cat >/etc/rancher/k3s/config.yaml <<EOF2
selinux: true
write-kubeconfig-mode: "0600"
flannel-backend: wireguard-native
flannel-iface-regex: "^(eth|ens|enp|eno|enx|wlan|wlp|wlo|bond|ib)"
node-ip: $K3S_NODE_IP
server: https://$K3S_SERVER_IP:6443
token: $K3S_JOIN_TOKEN
EOF2
    if ! command -v k3s >/dev/null 2>&1; then
        curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_START=true INSTALL_K3S_VERSION=stable sh -
    fi
    systemctl daemon-reload
    systemctl enable --now k3s
fi
REMOTE_SCRIPT
)"
ssh -t "$node_user@$node_ip" "sudo bash -s" <<<"$remote_script"

echo "==> Waiting for the node to register and become Ready"
node_name=""
for _ in $(seq 1 30); do
    node_name=$($SU "$kubectl_bin" get nodes -o json 2>/dev/null |
        jq -r --arg ip "$node_ip" '.items[] | select((.status.addresses // []) | any(.address == $ip)) | .metadata.name' |
        awk 'NR==1')
    [ -n "$node_name" ] || { sleep 5; continue; }
    $SU "$kubectl_bin" get node "$node_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True && break
    sleep 5
done
[ -n "$node_name" ] || { echo "Error: the joining node never registered" >&2; exit 1; }
echo "Node '$node_name' is Ready."

# Longhorn default-disk label; bump the replica count only when newly enabled.
longhorn_wanted=false
[ "$longhorn_replicas" = true ] && longhorn_wanted=true
current=$($SU "$kubectl_bin" get node "$node_name" -o json | jq -r '.metadata.labels["node.longhorn.io/create-default-disk"] // ""')
if [ "$current" != "$longhorn_wanted" ]; then
    $SU "$kubectl_bin" label node "$node_name" "node.longhorn.io/create-default-disk=$longhorn_wanted" --overwrite
    if [ "$longhorn_wanted" = true ]; then
        count=$($SU "$kubectl_bin" -n longhorn-system get setting.longhorn.io default-replica-count -o jsonpath='{.value}' 2>/dev/null || echo 0)
        $SU "$kubectl_bin" -n longhorn-system patch setting.longhorn.io default-replica-count \
            --type=merge -p "{\"value\":\"$((count + 1))\"}"
    fi
fi

if [ "$amdgpu_enabled" = true ]; then
    $SU "$kubectl_bin" patch node "$node_name" --type=merge -p '{"metadata":{"labels":{"has-amdgpu":"true"}}}'
fi

if [ "$scheduling_discouraged" = true ]; then
    taints=$($SU "$kubectl_bin" get node "$node_name" -o json | jq -r '(.spec.taints // []) | map(.key) | join(" ")')
    if [[ "$taints" != *scheduling-discouraged* ]]; then
        $SU "$kubectl_bin" taint node "$node_name" scheduling-discouraged=true:PreferNoSchedule --overwrite
    fi
fi

echo "k3s-join: node '$node_name' joined."
