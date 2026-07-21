#!/bin/bash
# DESC: Backup Compose runtime state (local file or remote via SSH)
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"

_prune_backups() {
    local target="$1"
    BACKUP_RETENTION=${BACKUP_RETENTION:-1}
    if [ "$BACKUP_RETENTION" -gt 0 ]; then
        local old_backups=()
        while IFS= read -r -d '' f; do
            old_backups+=("$f")
        done < <(find "$COMPOSE_STATE_BACKUP_DIR" -maxdepth 1 -name "$target-backup-*.tar" -printf '%T@ %p\0' | sort -rnz | cut -z -d' ' -f2- | tail -z -n +$((BACKUP_RETENTION + 1)))
        for old in "${old_backups[@]}"; do
            rm -f "$old"
            echo "Pruned old backup: $old"
        done
    fi
}

_prep_backup() {
    mkdir -p "$COMPOSE_STATE_BACKUP_DIR"
    date +%Y%m%d_%H%M%S
}

_usage() {
    cat >&2 <<'EOF'
Usage:
  atlas.sh <target> compose backup-state               Local backup (file in terminal, stream when piped)
  atlas.sh <target> compose backup-state -h            Show this help
  atlas.sh <target> compose backup-state <remote> <t>  Remote backup

Remote format:
  <remote>  [user@]host:path
  <t>       Target on the remote
EOF
}

case "${1:-}" in
    -h|--help)     _usage; exit 0 ;;
    *) ;;
esac
if [ $# -eq 1 ]; then
    _usage
    exit 1
fi

# ====== Remote mode ======
if [ $# -ge 2 ]; then
    remote_spec="$1"
    remote_target="$2"

    if [[ "$remote_spec" != *:* ]]; then
        _usage
        exit 1
    fi
    if ! command -v ssh >/dev/null 2>&1; then
        echo "ssh is required for remote backup but is not installed." >&2
        exit 1
    fi
    remote_host="${remote_spec%%:*}"
    remote_path="${remote_spec#*:}"

    TIMESTAMP=$(_prep_backup)
    OUTPUT="$COMPOSE_STATE_BACKUP_DIR/$remote_target-backup-$TIMESTAMP.tar"

    echo "Backing up $remote_target state from $remote_host..." >&2
    echo "  Output: $OUTPUT" >&2
    echo "  SSH: ssh -T $remote_host \"cd $remote_path && ATLAS_BACKUP_STREAM=true ./atlas.sh $remote_target compose backup-state\"" >&2

    tar_exit=0
    (umask 0077; ssh -T "$remote_host" "cd '$remote_path' && ATLAS_BACKUP_STREAM=true ./atlas.sh '$remote_target' compose backup-state" > "$OUTPUT") || tar_exit=$?
    if [ $tar_exit -ge 2 ]; then
        echo "Backup command failed on remote" >&2
        rm -f "$OUTPUT"
        exit 1
    fi
    if [ ! -s "$OUTPUT" ]; then
        echo "Backup failed: empty output" >&2
        rm -f "$OUTPUT"
        exit 1
    fi
    size=$(du -h "$OUTPUT" | awk '{print $1}')
    echo "Backup created: $OUTPUT ($size)" >&2
    _prune_backups "$remote_target"
    exit 0
fi

# ====== Local mode ======
if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required for backup-state but is not installed." >&2
    exit 1
fi
if [ ! -d "$COMPOSE_STATE_DIR" ]; then
    echo "State directory not found: $COMPOSE_STATE_DIR" >&2
    exit 1
fi

# Docker+tar pipeline that excludes FIFOs/sockets (they block reads indefinitely)
# --log-driver none prevents Docker from writing the tar stream to json-file logs on disk
docker_tar_cmd=(docker run --rm --log-driver none -v "$COMPOSE_STATE_DIR":/backup/state:ro \
    alpine sh -c 'apk add --no-cache tar >/dev/null && find /backup/state \( -type f -o -type d -o -type l \) -print0 | tar cf - --null -T - --sparse --ignore-failed-read --warning=no-file-changed --warning=no-file-removed')

# Size estimate for progress display
dir_size=$(du -sb "$COMPOSE_STATE_DIR" 2>/dev/null | awk '{print $1}') || dir_size=""

if [ -t 1 ] && [ "${ATLAS_BACKUP_STREAM:-}" != "true" ]; then
    # stdout is a terminal (and not explicitly streaming) → write to file
    TIMESTAMP=$(_prep_backup)
    OUTPUT="$COMPOSE_STATE_BACKUP_DIR/$TARGET-backup-$TIMESTAMP.tar"

    echo "Backing up $COMPOSE_STATE_DIR..."
    if [ -n "$dir_size" ]; then
        echo "State directory size: $(numfmt --to=iec $dir_size 2>/dev/null || echo "$dir_size bytes")"
    fi

    tar_exit=0
    "${docker_tar_cmd[@]}" > "$OUTPUT" || tar_exit=$?
    if [ $tar_exit -ge 2 ]; then
        echo "Backup failed" >&2
        rm -f "$OUTPUT"
        exit 1
    fi
    if [ -s "$OUTPUT" ]; then
        size=$(du -h "$OUTPUT" | awk '{print $1}')
        echo "Backup created: $OUTPUT ($size)"
        _prune_backups "$TARGET"
    else
        echo "Backup failed" >&2
        rm -f "$OUTPUT"
        exit 1
    fi
else
    # pipe/stream mode → tar to stdout, progress to stderr
    echo "Backing up $COMPOSE_STATE_DIR..." >&2
    if [ -n "$dir_size" ]; then
        echo "State directory size: $(numfmt --to=iec $dir_size 2>/dev/null || echo "$dir_size bytes")" >&2
    fi

    tar_exit=0
    "${docker_tar_cmd[@]}" || tar_exit=$?
    if [ $tar_exit -ge 2 ]; then
        exit $tar_exit
    fi
fi
