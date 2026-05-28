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

	echo "Backing up $remote_target state from $remote_host..." >&2
	echo "  Output: $OUTPUT" >&2
	echo "  SSH: ssh -T $remote_host \"cd $remote_path && ATLAS_BACKUP_STREAM=true ./atlas.sh $remote_target compose backup-state\"" >&2

	REMOTE_STATE_DIR="$remote_path/current_target/compose_live_state"
	pv_cmd=()
	if command -v pv >/dev/null 2>&1; then
		remote_size=$(ssh -T "$remote_host" "du -sb '$REMOTE_STATE_DIR' 2>/dev/null" 2>/dev/null | awk '{print $1}') || remote_size=""
		if [ -n "$remote_size" ]; then
			echo "Remote state directory size: $(numfmt --to=iec $remote_size 2>/dev/null || echo "$remote_size bytes")" >&2
			pv_cmd=(pv -pterb -s "$remote_size")
		else
			pv_cmd=(pv -pterb)
		fi
	fi

	if ! (umask 0077; ssh -T "$remote_host" "cd $remote_path && ATLAS_BACKUP_STREAM=true ./atlas.sh '$remote_target' compose backup-state" | "${pv_cmd[@]}" > "$OUTPUT"); then
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

# Docker+tar pipeline that excludes FIFOs/sockets (they block reads indefinitely)
docker_tar_cmd=(docker run --rm -v "$COMPOSE_STATE_DIR":/backup/state:ro \
	alpine sh -c 'apk add --no-cache tar >/dev/null && find /backup/state \( -type f -o -type d -o -type l \) -print0 | tar cf - --null -T - --ignore-failed-read')

# Size estimate for progress display
dir_size=$(du -sb "$COMPOSE_STATE_DIR" 2>/dev/null | awk '{print $1}') || dir_size=""

if [ -t 1 ] && [ "${ATLAS_BACKUP_STREAM:-}" != "true" ]; then
	# stdout is a terminal (and not explicitly streaming) → write to file
	TIMESTAMP=$(date +%Y%m%d_%H%M%S)
	mkdir -p "$COMPOSE_STATE_BACKUP_DIR"
	OUTPUT="$COMPOSE_STATE_BACKUP_DIR/$TARGET-backup-$TIMESTAMP.tar"

	echo "Backing up $COMPOSE_STATE_DIR..."
	if [ -n "$dir_size" ]; then
		echo "State directory size: $(numfmt --to=iec $dir_size 2>/dev/null || echo "$dir_size bytes")"
	fi

	pv_cmd=()
	if command -v pv >/dev/null 2>&1 && [ -n "$dir_size" ]; then
		pv_cmd=(pv -pterb -s "$dir_size")
	elif command -v pv >/dev/null 2>&1; then
		pv_cmd=(pv -pterb)
	fi

	"${docker_tar_cmd[@]}" | "${pv_cmd[@]}" > "$OUTPUT"
	if [ -s "$OUTPUT" ]; then
		size=$(du -h "$OUTPUT" | awk '{print $1}')
		echo "Backup created: $OUTPUT ($size)"
		prune_backups "$TARGET"
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

	pv_cmd=()
	if command -v pv >/dev/null 2>&1 && [ -n "$dir_size" ]; then
		pv_cmd=(pv -pterb -s "$dir_size")
	elif command -v pv >/dev/null 2>&1; then
		pv_cmd=(pv -pterb)
	fi

	"${docker_tar_cmd[@]}" | "${pv_cmd[@]}"
fi
