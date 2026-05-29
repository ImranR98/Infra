#!/bin/bash
# DESC: List Docker images older than 60 days
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"
docker images --no-trunc --format '{{.Repository}}:{{.Tag}}\t{{.CreatedAt}}' | while IFS=$'\t' read -r image created; do
	created_ts=$(date -d "$created" +%s 2>/dev/null) || continue
	days=$(( ($(date +%s) - created_ts) / 86400 ))
	if [ "$days" -gt 60 ]; then
		printf "%-50s %3d days\n" "$image" "$days"
	fi
done | sort -k2 -n
