#!/bin/bash
# DESC: Host preparation for control-plane / storage nodes
# Runs after prep-node.sh. Idempotent. Called by setup.sh and join.sh BEFORE K3s starts.
set -euo pipefail

source "$(dirname "$(readlink -f "$0")")/../../lib/common.sh"

HUGEPAGE_COUNT="$MAYASTOR_HUGEPAGE_COUNT"
HUGEPAGE_PATH="$MAYASTOR_HUGEPAGE_PATH"

# --- hugepages: allocate now ---
allocated=$(cat "$HUGEPAGE_PATH" 2>/dev/null || echo 0)
if [ "$allocated" -lt "$HUGEPAGE_COUNT" ]; then
	echo "$HUGEPAGE_COUNT" > "$HUGEPAGE_PATH"
fi

# --- hugepages: persistent across reboots ---
if ! grep -q "hugepages=" /etc/default/grub 2>/dev/null; then
	sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 default_hugepagesz=2M hugepagesz=2M hugepages='"$HUGEPAGE_COUNT"'"/' /etc/default/grub
	if command -v grub2-mkconfig >/dev/null 2>&1; then
		grub2-mkconfig -o /boot/grub2/grub.cfg
	elif command -v update-grub >/dev/null 2>&1; then
		update-grub
	fi
fi
grep -q "vm.nr_hugepages" /etc/sysctl.conf 2>/dev/null \
	|| echo "vm.nr_hugepages = $HUGEPAGE_COUNT" >> /etc/sysctl.conf

# --- backing file for Mayastor DiskPool ---
MAYASTOR_POOL_DIR="${MAYASTOR_POOL_DIR:?MAYASTOR_POOL_DIR must be set}"
mkdir -p "$MAYASTOR_POOL_DIR"
if [ ! -f "$MAYASTOR_POOL_DIR/pool.img" ]; then
	truncate -s 1T "$MAYASTOR_POOL_DIR/pool.img"
fi
