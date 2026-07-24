#!/bin/bash
# Restore strict permissions on the home directory after kubelet's
# hostPath volume processing sets the setgid bit and group-write.
# SSHd rejects connections if the home dir is group-writable.
set -euo pipefail
chmod 700 "$MAIN_PARENT_DIR"
chmod 644 "$MAIN_PARENT_DIR/wallpaper.png" 2>/dev/null || true
echo "Restored permissions on $MAIN_PARENT_DIR"
