#!/bin/bash
# DESC: Back up the compose runtime state of one target (tar via an Alpine
# container — skips FIFOs/sockets, so no mknod errors), pruning to
# BACKUP_RETENTION archives (default 1). With -e backup_remote=user@host:path
# the tar streams back over SSH from the remote machine (the remote runs
# docker directly — this script never runs there). Run ON the target.
set -euo pipefail

if [ -z "${INFRA_ROOT:-}" ]; then
    INFRA_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
    export INFRA_ROOT
fi
source "$INFRA_ROOT/scripts/common.sh"

usage() {
    echo "Usage: $(basename "$0") <target> [-e backup_remote=user@host:path]"
    echo
    echo "  <target>                  tars \$INFRA_ROOT/current_target/compose_live_state"
    echo "                            into compose_state_backups/<target>-backup-<ts>.tar"
    echo "  -e backup_remote=h:p      instead stream the tar over SSH from host h"
    echo "                            (remote repo checkout at path p)"
    exit 1
}

backup_remote=""
while [ $# -gt 0 ]; do
    case "$1" in
        -e)
            backup_remote="${2:-}"
            shift 2
            ;;
        -e*)
            backup_remote="${1#-e}"
            backup_remote="${backup_remote#=}"
            shift
            ;;
        -h | --help)
            usage
            ;;
        *)
            break
            ;;
    esac
done

[ $# -ge 1 ] || usage
require_target_host "$1"

retention="${BACKUP_RETENTION:-1}"
backup_dir="$INFRA_ROOT/compose_state_backups"
mkdir -p "$backup_dir"
umask 0077

tar_cmd='apk add --no-cache tar >/dev/null && find /backup/state \( -type f -o -type d -o -type l \) -print0 | tar cf - --null -T - --sparse --ignore-failed-read --warning=no-file-changed --warning=no-file-removed'

if [ -n "$backup_remote" ]; then
    host="${backup_remote%%:*}"
    path="${backup_remote#*:}"
    out="$backup_dir/${TARGET}-backup-$(date +%Y%m%d_%H%M%S).tar"
    echo "Backing up compose state from $host (remote checkout at $path)..."
    ssh -T "$host" "cd '$path' && docker run --rm --log-driver none -v \$PWD/current_target/compose_live_state:/backup/state:ro alpine sh -c '$tar_cmd'" >"$out"
else
    state_dir="$INFRA_ROOT/current_target/compose_live_state"
    if [ ! -d "$state_dir" ]; then
        echo "Error: state directory not found: $state_dir" >&2
        exit 1
    fi
    out="$backup_dir/${TARGET}-backup-$(date +%Y%m%d_%H%M%S).tar"
    echo "Backing up compose state at $state_dir..."
    docker run --rm --log-driver none -v "$state_dir":/backup/state:ro alpine \
        sh -c "$tar_cmd" >"$out"
fi

echo "Backup created: $out"
ls -1t "$backup_dir"/"${TARGET}"-backup-*.tar 2>/dev/null |
    tail -n +$((retention + 1)) | xargs -r rm -f
