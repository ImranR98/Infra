#!/usr/bin/env bash
# DESC: Check (and optionally create) the host paths the Task Runner mounts.
# Run this on the host that owns the Main tree before the first deploy.
#
#   bash scripts/preflight-task-runner.sh
#   bash scripts/preflight-task-runner.sh --fix
#
# The pod's prepare-runtime initContainer handles paths visible inside the
# cluster. This script only covers what must exist before that pod can start:
# the hostPath Main directories and the private config checkout.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"
set_my_uid

FIX=0
MAIN_PARENT_DIR="${MAIN_PARENT_DIR:-}"
CONFIG_DIR="${TASK_RUNNER_CONFIG_DIR:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --fix) FIX=1 ;;
        --main-dir) shift; MAIN_PARENT_DIR="${1:-}" ;;
        --config-dir) shift; CONFIG_DIR="${1:-}" ;;
        --help|-h)
            sed -n '2,8p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
    shift
done

if [ -z "$MAIN_PARENT_DIR" ]; then
    values="$INFRA_ROOT/config/srv0/values.yaml"
    [ -f "$values" ] || { echo "Error: $values not found; pass --main-dir" >&2; exit 1; }
    MAIN_PARENT_DIR="$(yq -r '.MAIN_PARENT_DIR // ""' "$values")"
fi
if [ -z "$MAIN_PARENT_DIR" ] || [ "$MAIN_PARENT_DIR" = "null" ]; then
    echo "Error: MAIN_PARENT_DIR is not configured; pass --main-dir" >&2
    exit 1
fi

MAIN_DIR="$MAIN_PARENT_DIR/Main"
CONFIG_DIR="${CONFIG_DIR:-$MAIN_DIR/Code/Automation/dscpln-config}"
REQUIRED=(
    "$MAIN_DIR/Backups"
    "$MAIN_DIR/Media"
    "$MAIN_DIR/Documents"
    "$MAIN_DIR/Infra/state_backups"
)

fail=0
check_dir() {
    local dir="$1"
    if [ -d "$dir" ]; then
        echo "  [OK] $dir"
    elif [ "$FIX" = 1 ]; then
        echo "  [CREATE] $dir"
        sudo mkdir -p "$dir"
        sudo chown "$MY_UID:$MY_UID" "$dir"
        sudo chmod 2775 "$dir"
    else
        echo "  [MISSING] $dir (run with --fix)" >&2
        fail=1
    fi
}

echo "==> Task Runner host paths (UID $MY_UID)"
for dir in "${REQUIRED[@]}"; do
    check_dir "$dir"
done

if [ ! -d "$CONFIG_DIR" ]; then
    echo "  [MISSING] $CONFIG_DIR" >&2
    echo "Clone the private dscpln-config repo there as UID $MY_UID first." >&2
    exit 1
fi
owner="$(stat -c %u "$CONFIG_DIR")"
if [ "$owner" != "$MY_UID" ]; then
    echo "  [WRONG OWNER] $CONFIG_DIR is owned by UID $owner; expected $MY_UID" >&2
    echo "Fix with: sudo chown -R $MY_UID:$MY_UID '$CONFIG_DIR'" >&2
    fail=1
else
    echo "  [OK] $CONFIG_DIR (owner $owner)"
fi

for file in "$CONFIG_DIR/task-meta.json" "$CONFIG_DIR/tools/contacts/config.json"; do
    [ -e "$file" ] || continue
    owner="$(stat -c %u "$file")"
    if [ "$owner" != "$MY_UID" ]; then
        if [ "$FIX" = 1 ]; then
            echo "  [FIX] $file owner $owner -> $MY_UID"
            sudo chown "$MY_UID:$MY_UID" "$file"
        else
            echo "  [WRONG OWNER] $file is owned by UID $owner; expected $MY_UID (run with --fix)" >&2
            fail=1
        fi
    fi
done

if [ "$fail" -ne 0 ]; then
    exit 1
fi
echo "==> Task Runner host paths are ready"
