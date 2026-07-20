#!/bin/bash
set -euo pipefail
mkdir -p "$PVC_BACKUP_DIR"
chcon -t container_file_t "$PVC_BACKUP_DIR" 2>/dev/null || true
