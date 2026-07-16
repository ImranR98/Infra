#!/bin/bash
# DESC: Validate that host prep (commands/k3s/prep-{node,control-plane}.sh) has run
set -euo pipefail

if ! lsmod | grep -q nvme_tcp; then
	echo "ERROR: nvme_tcp kernel module not loaded. Run prep-node.sh first." >&2
	exit 1
fi
allocated=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null || echo 0)
if [ "$allocated" -lt 1024 ]; then
	echo "ERROR: hugepages not configured. Run prep-control-plane.sh first." >&2
	exit 1
fi
