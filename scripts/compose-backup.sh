#!/bin/bash
# DESC: Back up the compose runtime state of one target (tar via an Alpine
# container — skips FIFOs/sockets, so no mknod errors; tar exit 1 from files
# changing mid-read is expected for live state and accepted), pruning to
# BACKUP_RETENTION archives (default 1); a failed run removes its partial
# archive. Local mode tars this checkout's current_target/compose_live_state
# and must run ON the target; it asserts hostname == target. With
# -e backup_remote=user@host:path the tar instead streams back over SSH from
# the remote checkout (the remote runs docker directly — this script never
# runs there), so it can run from any machine; a remote hostname that differs
# from <target> only warns.
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
    echo "                            (run ON the target)"
    echo "  -e backup_remote=h:p      instead stream the tar over SSH from host h"
    echo "                            (remote repo checkout at path p) into this"
    echo "                            machine's compose_state_backups/, named after"
    echo "                            <target>; runs from any machine and only warns"
    echo "                            when h's hostname differs from <target>"
    exit 1
}

backup_remote=""
target_arg=""
have_remote=false
while [ $# -gt 0 ]; do
    case "$1" in
        -e)
            [ $# -ge 2 ] || usage
            backup_remote="$2"
            have_remote=true
            shift 2
            ;;
        -e*)
            backup_remote="${1#-e}"
            have_remote=true
            shift
            ;;
        -h | --help)
            usage
            ;;
        -*)
            echo "Error: unknown option '$1'" >&2
            usage
            ;;
        *)
            [ -z "$target_arg" ] || usage
            target_arg="$1"
            shift
            ;;
    esac
done
if [ "$have_remote" = true ]; then
    backup_remote="${backup_remote#=}"
    backup_remote="${backup_remote#backup_remote=}"
    if [[ "$backup_remote" != *:* ]]; then
        echo "Error: -e backup_remote needs user@host:path" >&2
        usage
    fi
fi
[ -n "$target_arg" ] || usage

if [ -n "$backup_remote" ]; then
    require_target "$target_arg"
else
    require_target_host "$target_arg"
fi

retention="${BACKUP_RETENTION:-1}"
backup_dir="$INFRA_ROOT/compose_state_backups"
mkdir -p "$backup_dir"
umask 0077

# apk failure exits 2 so it can't be mistaken for tar's tolerated exit 1.
# shellcheck disable=SC2016  # $?/$rc expand in the container's sh, not locally
tar_cmd='apk add --no-cache tar >/dev/null || exit 2; find /backup/state \( -type f -o -type d -o -type l \) -print0 | tar cf - --null -T - --sparse --ignore-failed-read --warning=no-file-changed --warning=no-file-removed; rc=$?; if [ "$rc" -gt 1 ]; then exit "$rc"; fi; [ "$rc" -eq 1 ] && echo "Note: some live files changed during the backup; the archive was still written" >&2; exit 0'

if [ -n "$backup_remote" ]; then
    host="${backup_remote%%:*}"
    path="${backup_remote#*:}"
    out="$backup_dir/${TARGET}-backup-$(date +%Y%m%d_%H%M%S).tar"
    remote_hostname="$(ssh -T "$host" hostname 2>/dev/null)" || remote_hostname=""
    if [ -n "$remote_hostname" ] && [ "$remote_hostname" != "$TARGET" ]; then
        echo "Warning: remote host '$host' is named '$remote_hostname', not target '$TARGET'; saving as $(basename "$out")" >&2
    fi
    echo "Backing up compose state from $host (remote checkout at $path)..."
    if ! ssh -T "$host" "cd '$path' && test -d current_target/compose_live_state && docker run --rm --log-driver none -v \$PWD/current_target/compose_live_state:/backup/state:ro alpine sh -c '$tar_cmd'" >"$out"; then
        echo "Error: remote backup failed; removed partial archive $out" >&2
        rm -f "$out"
        exit 1
    fi
else
    state_dir="$INFRA_ROOT/current_target/compose_live_state"
    if [ ! -d "$state_dir" ]; then
        echo "Error: state directory not found: $state_dir" >&2
        exit 1
    fi
    out="$backup_dir/${TARGET}-backup-$(date +%Y%m%d_%H%M%S).tar"
    echo "Backing up compose state at $state_dir..."
    if ! docker run --rm --log-driver none -v "$state_dir":/backup/state:ro alpine \
        sh -c "$tar_cmd" >"$out"; then
        echo "Error: backup failed; removed partial archive $out" >&2
        rm -f "$out"
        exit 1
    fi
fi

echo "Backup created: $out"
ls -1t "$backup_dir"/"${TARGET}"-backup-*.tar 2>/dev/null |
    tail -n +$((retention + 1)) | xargs -r rm -f
