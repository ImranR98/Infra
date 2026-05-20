#!/bin/bash
set -euo pipefail

COMP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
export VARS_ROOT="$(cd "$COMP_DIR/../../../.." >/dev/null 2>&1 && pwd)"
export TARGET="$(basename "$(cd "$COMP_DIR/../.." >/dev/null 2>&1 && pwd)")"
source "$VARS_ROOT/lib/vars.sh"