#!/bin/bash
# lib/retry.sh — retry utility

retry() {
    local tries="${1:-30}"
    local delay="${2:-5}"
    shift 2
    for _ in $(seq 1 "$tries"); do
        eval "$*" 2>/dev/null && return 0
        sleep "$delay"
    done
    return 1
}
