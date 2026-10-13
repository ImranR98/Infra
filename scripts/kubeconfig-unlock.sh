#!/bin/bash
# DESC: Unlock the K3s admin kubeconfig for this user's dev session: grant a
# user read ACL on /etc/rancher/k3s/k3s.yaml and symlink ~/.kube/config to it,
# then hold until interrupted (Ctrl-C) and remove both. While held, the ACL is
# re-asserted automatically if k3s rewrites the kubeconfig (its chmod 0600
# clears the ACL mask on restart/cert rotation), so the unlock stays effective
# for the whole session without re-running. `--lock` removes a leftover unlock
# (e.g. after a SIGKILL). Machine-local, run as the user.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"

SU="sudo"
K3S_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
USER_KUBECONFIG="$HOME/.kube/config"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--lock]   (run as your user, no target)

  (no args)  grant a read ACL on the K3s kubeconfig + symlink ~/.kube/config,
             then wait until Ctrl-C removes both (self-heals k3s rewrites)
  --lock     remove a leftover unlock (e.g. after the script was killed)
EOF
    exit 1
}

# k3s's bundled kubectl ignores ~/.kube/config and reads the k3s default path,
# so kubectl needs the ACL; helm uses the symlink. While this script holds, the
# watchdog re-applies the ACL whenever k3s clobbers it on restart/rotation.
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
# The explicit mask matters: chmod 600 (k3s's write-kubeconfig-mode) collapses
# the ACL mask to ---, which silently nullifies the named-user entry.
$SU setfacl -m "u:$(id -un):r,m::r" "$K3S_KUBECONFIG"
ln -sfn "$K3S_KUBECONFIG" "$USER_KUBECONFIG"

echo "kubeconfig unlocked for $(id -un):"
echo "  $USER_KUBECONFIG -> $K3S_KUBECONFIG (read ACL)"
echo "kubectl and helm now work in every shell. Press Ctrl-C to lock."
# Watchdog: k3s rewrites the kubeconfig on restart/cert rotation and its chmod
# clears the ACL mask; re-assert whenever our read access disappears. The
# re-assert needs sudo, so when the cached credentials expire and cannot be
# refreshed (no terminal), exit loudly instead of silently degrading to a
# watchdog that does nothing.
while :; do
    sleep 15
    [ -e "$USER_KUBECONFIG" ] || ln -sfn "$K3S_KUBECONFIG" "$USER_KUBECONFIG"
    [ -r "$K3S_KUBECONFIG" ] && continue
    if ! $SU -n true 2>/dev/null; then
        if [ -t 0 ]; then
            $SU -v || { echo "kubeconfig-unlock: sudo refresh failed; re-run this script." >&2; exit 1; }
        else
            echo "kubeconfig-unlock: sudo credentials expired — the ACL cannot be re-asserted." >&2
            echo "Re-run $(basename "$0") from a terminal to unlock again." >&2
            exit 1
        fi
    fi
    $SU setfacl -m "u:$(id -un):r,m::r" "$K3S_KUBECONFIG" || true
done
