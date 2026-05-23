#!/bin/bash
set -euo pipefail
source "$ATLAS_ROOT/lib/common.sh"
source "$ATLAS_ROOT/lib/validate.sh"
validate "$TARGET"
