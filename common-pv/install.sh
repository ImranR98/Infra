#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

mkdir -p "$MAIN_PARENT_DIR"/deviceSync/Calls
mkdir -p "$MAIN_PARENT_DIR"/deviceSync/DCIM
mkdir -p "$MAIN_PARENT_DIR"/deviceSync/ScreenRecs
mkdir -p "$MAIN_PARENT_DIR"/deviceSync/Screenshots