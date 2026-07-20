#!/bin/bash
set -euo pipefail
mkdir -p "$PVC_BACKUP_DIR"
chcon -t container_file_t -l s0 "$PVC_BACKUP_DIR" 2>/dev/null || true
