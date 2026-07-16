#!/bin/bash
# DESC: Host preparation for every K3s node (control-plane and workers)
# Idempotent. Called by setup.sh and join.sh BEFORE K3s starts.
set -euo pipefail

MODULES_CONF=/etc/modules-load.d/mayastor.conf

if [ ! -f "$MODULES_CONF" ]; then
	echo "nvme_tcp" | tee "$MODULES_CONF"
fi
modprobe nvme_tcp 2>/dev/null || true
