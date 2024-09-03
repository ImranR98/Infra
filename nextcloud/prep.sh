#!/bin/bash -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
mkdir -p "$HERE"/../state/nextcloud/db
mkdir -p "$HERE"/../state/nextcloud/data