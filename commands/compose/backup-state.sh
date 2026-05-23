#!/bin/bash
set -euo pipefail
source "$VARS_ROOT/lib/common.sh"

if ! command -v docker >/dev/null 2>&1; then
	echo "Docker is required for backup-state but is not installed." >&2
	exit 1
fi
if [ ! -d "$COMPOSE_STATE_DIR" ]; then
	echo "State directory not found: $COMPOSE_STATE_DIR" >&2
	exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "$COMPOSE_STATE_BACKUP_DIR"
OUTPUT="$COMPOSE_STATE_BACKUP_DIR/$TARGET-backup-$TIMESTAMP.tar"

echo "Backing up $COMPOSE_STATE_DIR..."
(umask 0077; docker run --rm -v "$COMPOSE_STATE_DIR":/backup/state:ro \
	alpine sh -c 'apk add --no-cache tar >/dev/null 2>&1 && exec tar cf - --ignore-failed-read --warning=no-file-changed --warning=no-file-removed -C /backup state' > "$OUTPUT")
if [ -s "$OUTPUT" ]; then
	echo "Backup created: $OUTPUT"
	BACKUP_RETENTION=${BACKUP_RETENTION:-1}
	if [ "$BACKUP_RETENTION" -gt 0 ]; then
		old_backups=()
		while IFS= read -r -d '' f; do
			old_backups+=("$f")
		done < <(find "$COMPOSE_STATE_BACKUP_DIR" -maxdepth 1 -name "$TARGET-backup-*.tar" -printf '%T@ %p\0' | sort -rnz | cut -z -d' ' -f2- | tail -n +$((BACKUP_RETENTION + 1)))
		for old in "${old_backups[@]}"; do
			rm -f "$old"
			echo "Pruned old backup: $old"
		done
	fi
else
	echo "Backup failed" >&2
	rm -f "$OUTPUT"
	exit 1
fi
