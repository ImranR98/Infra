#!/bin/bash
set -e

# Shows local images older than 60 days

OLD_IMAGES="$(current_time=$(date +%s); docker images --no-trunc --format "{{.Repository}}:{{.Tag}}\t{{.CreatedAt}}" | while IFS=$'\t' read image created; do created_clean=$(echo "$created" | sed 's/ [A-Z]\{3,\}$//'); created_time=$(date -d "$created_clean" +%s 2>/dev/null); if [[ -n "$created_time" ]]; then days=$(( (current_time - created_time) / 86400 )); created_date=$(echo "$created" | cut -d' ' -f1); printf "%-50s %3d days\n" "$image" "$days"; fi; done | sort -k2 -n | awk '$(NF-1) > 60')"

echo "$OLD_IMAGES"