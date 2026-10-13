#!/bin/bash
# DESC: Install the monthly Docker image-prune systemd timer on vps0 — reclaims
# images left behind by the pinned-digest workflow (Renovate bumps pin a new
# digest; nothing removes the old images).
set -euo pipefail
SU="sudo"

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"
require_target_host vps0

usage() {
    echo "Usage: $(basename "$0")"
    echo
    echo "Installs targets/vps0/docker-prune/docker-image-prune.{service,timer} into"
    echo "/etc/systemd/system and enables the monthly timer. Idempotent."
    exit 1
}

[ $# -ge 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; } && usage
[ $# -gt 0 ] && usage

src_dir="$INFRA_ROOT/targets/vps0/docker-prune"

echo "==> Installing docker-image-prune units"
$SU install -m 0644 "$src_dir/docker-image-prune.service" /etc/systemd/system/docker-image-prune.service
$SU install -m 0644 "$src_dir/docker-image-prune.timer" /etc/systemd/system/docker-image-prune.timer

$SU systemctl daemon-reload
$SU systemctl enable --now docker-image-prune.timer

echo "Done. Inspect with: systemctl list-timers docker-image-prune.timer"
