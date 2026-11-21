#!/bin/bash
# DESC: Initialise a target's gitignored config tree from config_template and
# optionally detect the local UID. Existing files are never overwritten.
#
# Usage: init-config.sh <target> [--detect]
#   Run --detect on srv0 to set MY_UID. Accelerator/HA hardware is fixed in the
#   charts; no profile values are written.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
# shellcheck disable=SC1091
source "$INFRA_ROOT/scripts/common.sh"

usage() {
    echo "Usage: $(basename "$0") <target> [--detect]" >&2
    echo "Targets: $(find "$INFRA_ROOT/targets" -mindepth 1 -maxdepth 1 -type d -printf '%f ')" >&2
    exit 1
}

[ $# -ge 1 ] || usage
target="$1"
shift
detect=0
while [ $# -gt 0 ]; do
    case "$1" in
        --detect) detect=1 ;;
        -h | --help) usage ;;
        *) usage ;;
    esac
    shift
done
_require_target "$target"

template="$INFRA_ROOT/targets/$target/config_template"
config_dir="$INFRA_ROOT/config/$target"
mkdir -p "$config_dir"
if [ -d "$template" ]; then
    cp -an "$template/." "$config_dir/" 2>/dev/null || true
fi

if [ "$detect" = 1 ] && [ "$target" = "srv0" ]; then
    values="$config_dir/values.yaml"
    [ -f "$values" ] || { echo "Error: $values missing" >&2; exit 1; }

    my_uid="${MY_UID:-$(id -u)}"
    yq -i ".MY_UID = $my_uid" "$values"
    echo "==> Detected srv0 UID: $my_uid (accelerator/HA hardware is fixed in-chart)"
fi

echo "==> Config initialised at $config_dir"
echo "Next:"
echo "  - fill config/$target values/compose env"
echo "  - vps0: fill authelia/users_database.yml and access_control.yml"
echo "  - srv0: fill the public-exposure host/port, then run scripts/public-exposure-keygen.sh"
echo "  - run: bash scripts/validate.sh $target"
