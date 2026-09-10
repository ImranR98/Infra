#!/bin/bash
# DESC: Unlock the K3s admin kubeconfig for this user's dev session: grant a
# user read ACL on /etc/rancher/k3s/k3s.yaml and symlink ~/.kube/config to it,
# then hold until interrupted (Ctrl-C) and remove both. `--lock` removes a
# leftover unlock (e.g. after a SIGKILL). Machine-local, run as the user.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"

SU="$(get_sudo_cmd)"
K3S_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
USER_KUBECONFIG="$HOME/.kube/config"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--lock]   (run as your user, no target)

  (no args)  grant a read ACL on the K3s kubeconfig + symlink ~/.kube/config,
             then wait until Ctrl-C removes both
  --lock     remove a leftover unlock (e.g. after the script was killed)
EOF
    exit 1
}

# k3s's bundled kubectl ignores ~/.kube/config and reads the k3s default path,
# so kubectl needs the ACL; helm uses the symlink. k3s rewrites the kubeconfig
# (and chmod clears the ACL mask) on restart/cert rotation — re-run afterwards.
lock() {
    if [ -L "$USER_KUBECONFIG" ] && [ "$(readlink "$USER_KUBECONFIG")" = "$K3S_KUBECONFIG" ]; then
        rm -f "$USER_KUBECONFIG"
    fi
    $SU setfacl -x "u:$(id -un)" "$K3S_KUBECONFIG" 2>/dev/null || true
}

case "${1:-}" in
    --lock)
        lock
        echo "kubeconfig locked."
        exit 0
        ;;
    -h | --help) usage ;;
    "") ;;
    *) usage ;;
esac

[ "$(id -u)" -ne 0 ] || { echo "Error: run as your user — root doesn't need the unlock." >&2; exit 1; }
[ -f "$K3S_KUBECONFIG" ] || { echo "Error: $K3S_KUBECONFIG not found — is K3s installed here?" >&2; exit 1; }
command -v setfacl >/dev/null 2>&1 || { echo "Error: setfacl not found — install the 'acl' package." >&2; exit 1; }
if [ -n "${KUBECONFIG:-}" ]; then
    echo "Warning: KUBECONFIG is set ($KUBECONFIG) — kubectl will use that, not this unlock." >&2
fi
if [ -e "$USER_KUBECONFIG" ] && [ ! -L "$USER_KUBECONFIG" ]; then
    echo "Error: $USER_KUBECONFIG exists and is not a symlink; refusing to overwrite." >&2
    exit 1
fi

trap lock EXIT
trap 'exit 0' INT TERM HUP

mkdir -p "$HOME/.kube"
chmod 700 "$HOME/.kube"
$SU setfacl -m "u:$(id -un):r" "$K3S_KUBECONFIG"
ln -sfn "$K3S_KUBECONFIG" "$USER_KUBECONFIG"

echo "kubeconfig unlocked for $(id -un):"
echo "  $USER_KUBECONFIG -> $K3S_KUBECONFIG (read ACL)"
echo "kubectl and helm now work in every shell. Press Ctrl-C to lock."
while :; do sleep 3600; done
