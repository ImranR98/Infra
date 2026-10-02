#!/bin/bash
# DESC: Fetch a generated WireGuard client profile from the wireguard pod's
# PVC. Run ON any machine with an unlocked kubeconfig (scripts/kubeconfig-unlock.sh).
# The profile is written to config/$(hostname)/wg/<client>.conf (0600) by
# default; --stdout prints it.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"

usage() {
    echo "Usage: $(basename "$0") <client> [out-file | --stdout]"
    echo
    echo "Fetches /wg/<client>.conf from the base/wireguard pod (generated on the"
    echo "wireguard-pvc) and writes config/$(hostname)/wg/<client>.conf (0600) by"
    echo "default. Requires an unlocked kubeconfig (scripts/kubeconfig-unlock.sh)."
    exit 1
}

client="${1:-}"
out="${2:-$INFRA_ROOT/config/$(hostname)/wg/$client.conf}"
case "$client" in
    ""|-h|--help) usage ;;
esac

conf="$(kubectl -n base exec -c wireguard deploy/wireguard -- cat "/wg/$client.conf" 2>/dev/null)" || {
    echo "Error: no profile /wg/$client.conf in the wireguard pod (unlocked kubeconfig? client name?)" >&2
    exit 1
}
grep -q '^\[Interface\]' <<<"$conf" || {
    echo "Error: fetched profile for '$client' looks invalid" >&2
    exit 1
}

case "$out" in
    --stdout)
        printf '%s\n' "$conf"
        ;;
    *)
        mkdir -p "$(dirname "$out")"
        (umask 077; printf '%s\n' "$conf" >"$out")
        echo "wrote $out"
        ;;
esac
