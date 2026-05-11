#!/bin/bash
set -euo pipefail

# Shows local images older than 60 days

current_time=$(date +%s)
docker images --no-trunc --format "{{.Repository}}:{{.Tag}}\t{{.CreatedAt}}" | \
    while IFS=$'\t' read -r image created; do
        created_time=$(date -d "$created" +%s 2>/dev/null) || continue
        days=$(( (current_time - created_time) / 86400 ))
        if [ "$days" -gt 60 ]; then
            printf "%-50s %3d days\n" "$image" "$days"
        fi
    done | sort -k2 -n