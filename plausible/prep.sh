#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
mkdir -p "$STATE_DIR"/plausible/db
mkdir -p "$STATE_DIR"/plausible/clickhouse/data
mkdir -p "$STATE_DIR"/plausible/clickhouse/logs
