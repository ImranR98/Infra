#!/bin/bash
# DESC: Bootstrap THIS machine as the K3s control plane: node prep, the official
# get.k3s.io installer, server config (cluster-init, flannel-wireguard), and
# the post-install Longhorn default-disk label. Run ON the node — no args.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"

usage() {
    echo "Usage: $(basename "$0")   (run ON the control-plane machine, no args)"
    exit 1
}

[ $# -ge 1 ] && { case "$1" in -h | --help) usage ;; esac; }

SU="$(get_sudo_cmd)"
node_ip="$(get_node_ip)"
[ -n "$node_ip" ] || { echo "Error: cannot determine this machine's IP" >&2; exit 1; }

echo "==> Node prep"
$SU env K3S_ROLE=server bash "$INFRA_ROOT/scripts/k3s-node-prep.sh"

# The installer only runs when k3s is missing — re-running never re-installs,
# so it can't fight system-upgrade-controller's ownership of upgrades.
echo "==> Installing K3s"
if ! command -v k3s >/dev/null 2>&1; then
    curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_START=true INSTALL_K3S_VERSION=stable sh -
fi

echo "==> Writing server config"
# Flannel selects the interface owning node-ip, so no flannel-iface is needed
# to keep VPN interfaces out. The lease flags keep the in-process controller
# manager and scheduler from exiting k3s when multi-second etcd write stalls
# make them miss a lease renewal.
$SU mkdir -p /etc/rancher/k3s
$SU tee /etc/rancher/k3s/config.yaml >/dev/null <<EOF
selinux: true
write-kubeconfig-mode: "0600"
flannel-backend: wireguard-native
cluster-init: true
node-ip: $node_ip
kube-controller-manager-arg:
  - leader-elect-lease-duration=60s
  - leader-elect-renew-deadline=40s
  - leader-elect-retry-period=5s
kube-scheduler-arg:
  - leader-elect-lease-duration=60s
  - leader-elect-renew-deadline=40s
  - leader-elect-retry-period=5s
EOF

echo "==> Starting K3s"
$SU systemctl daemon-reload
$SU systemctl enable --now k3s

echo "==> Waiting for the server token and the API"
for _ in $(seq 1 60); do
    [ -f /var/lib/rancher/k3s/server/token ] && break
    sleep 5
done
[ -f /var/lib/rancher/k3s/server/token ] || { echo "Error: k3s server token never appeared" >&2; exit 1; }

# The kubeconfig is root-only — run the cluster calls as root.
kubectl_bin="$(command -v kubectl)" || { echo "Error: kubectl not found" >&2; exit 1; }
for _ in $(seq 1 24); do
    $SU "$kubectl_bin" get nodes >/dev/null 2>&1 && break
    sleep 5
done
$SU "$kubectl_bin" get nodes >/dev/null 2>&1 || { echo "Error: Kubernetes API never became reachable" >&2; exit 1; }

echo "==> Longhorn default-disk label"
$SU "$kubectl_bin" patch node "$(hostname)" --type=merge \
    -p '{"metadata":{"labels":{"node.longhorn.io/create-default-disk":"true"}}}'

echo "k3s-server: control plane ready."
