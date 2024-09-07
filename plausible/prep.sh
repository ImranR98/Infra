#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
mkdir -p "$HERE"/../state/plausible/db
mkdir -p "$HERE"/../state/plausible/clickhouse/data
mkdir -p "$HERE"/../state/plausible/clickhouse/logs
