#!/bin/bash
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"

prune_backups() {
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

usage() {
	cat >&2 <<'EOF'
Usage:
  atlas.sh <target> compose backup-state               Local backup (file in terminal, stream when piped)
  atlas.sh <target> compose backup-state -h            Show this help
  atlas.sh <target> compose backup-state <remote> <t>  Remote backup

Remote format:
  <remote>  [user@]host:path (e.g. root@luna.example.org:~/Atlas)
  <t>       Target on the remote (e.g. luna)
EOF
	exit 1
}

case "${1:-}" in
	-h|--help) usage ;;
	*) ;;
esac
if [ $# -eq 1 ]; then
	usage
fi

# --- Remote mode ---
if [ $# -ge 2 ]; then
	remote_spec="$1"
	remote_target="$2"

	if [[ "$remote_spec" != *:* ]]; then
		usage
	fi
	if ! command -v ssh >/dev/null 2>&1; then
		echo "ssh is required for remote backup but is not installed." >&2
		exit 1
	fi
	remote_host="${remote_spec%%:*}"
	remote_path="${remote_spec#*:}"

	TIMESTAMP=$(date +%Y%m%d_%H%M%S)
	mkdir -p "$COMPOSE_STATE_BACKUP_DIR"
	OUTPUT="$COMPOSE_STATE_BACKUP_DIR/$remote_target-backup-$TIMESTAMP.tar"

	echo "Backing up $remote_target state from $remote_host..."
	if ! (umask 0077; ssh "$remote_host" "cd $remote_path && ./atlas.sh '$remote_target' compose backup-state" > "$OUTPUT"); then
		echo "Backup command failed on remote" >&2
		rm -f "$OUTPUT"
		exit 1
	fi
	if [ ! -s "$OUTPUT" ]; then
		echo "Backup failed: empty output" >&2
		rm -f "$OUTPUT"
		exit 1
	fi
	echo "Backup created: $OUTPUT"
	prune_backups "$remote_target"
	exit 0
fi

# --- Local mode ---
if ! command -v docker >/dev/null 2>&1; then
	echo "Docker is required for backup-state but is not installed." >&2
	exit 1
fi
if [ ! -d "$COMPOSE_STATE_DIR" ]; then
	echo "State directory not found: $COMPOSE_STATE_DIR" >&2
	exit 1
fi

if [ -t 1 ]; then
	# stdout is a terminal → write to file (original behavior)
	TIMESTAMP=$(date +%Y%m%d_%H%M%S)
	mkdir -p "$COMPOSE_STATE_BACKUP_DIR"
	OUTPUT="$COMPOSE_STATE_BACKUP_DIR/$TARGET-backup-$TIMESTAMP.tar"

	echo "Backing up $COMPOSE_STATE_DIR..."
	(umask 0077; docker run --rm -v "$COMPOSE_STATE_DIR":/backup/state:ro \
		alpine sh -c 'apk add --no-cache tar >/dev/null && exec tar cf - --ignore-failed-read --warning=no-file-changed --warning=no-file-removed -C /backup state' > "$OUTPUT")
	if [ -s "$OUTPUT" ]; then
		echo "Backup created: $OUTPUT"
		prune_backups "$TARGET"
	else
		echo "Backup failed" >&2
		rm -f "$OUTPUT"
		exit 1
	fi
else
	# stdout is not a terminal → stream tar to stdout (for remote piped usage)
	echo "Backing up $COMPOSE_STATE_DIR..." >&2
	docker run --rm -v "$COMPOSE_STATE_DIR":/backup/state:ro \
		alpine sh -c 'apk add --no-cache tar >/dev/null && exec tar cf - --ignore-failed-read --warning=no-file-changed --warning=no-file-removed -C /backup state'
fi
