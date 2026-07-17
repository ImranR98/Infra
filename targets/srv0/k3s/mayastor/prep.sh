#!/bin/bash
# DESC: Validate that host prep (commands/k3s/prep-{node,control-plane}.sh) has run
set -euo pipefail

source "$(dirname "$(readlink -f "$0")")/../../../../../../lib/common.sh"

if ! grep -q nvme_tcp /proc/modules; then
	echo "ERROR: nvme_tcp kernel module not loaded. Run prep-node.sh first." >&2
	exit 1
fi
allocated=$(cat "$MAYASTOR_HUGEPAGE_PATH" 2>/dev/null || echo 0)
if [ "$allocated" -lt "$MAYASTOR_HUGEPAGE_COUNT" ]; then
	echo "ERROR: hugepages not configured. Run prep-control-plane.sh first." >&2
	exit 1
fi
