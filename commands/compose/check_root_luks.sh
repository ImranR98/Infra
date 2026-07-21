#!/bin/bash
# DESC: Check whether the root partition uses LUKS encryption
set -euo pipefail

# Resolve root device, stripping subvol/path suffixes
root_source=$(findmnt -n -o SOURCE /sysroot 2>/dev/null | sed 's/\[.*//') || true
if [[ -z "$root_source" ]]; then
    root_source=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/\[.*//') || true
fi
if [[ -z "$root_source" ]]; then
    echo "Error: Could not determine root device." >&2
    exit 1
fi

# Check if the root source is a block device
if [[ ! -b "$root_source" ]]; then
    echo "Root filesystem is not on a block device (e.g., tmpfs). Not encrypted with LUKS." >&2
    exit 1
fi

# Check if the device or any of its dependencies are crypt devices
if lsblk -s -o TYPE "$root_source" | grep -q 'crypt'; then
    echo "Root partition is on a LUKS encrypted drive."
    exit 0
else
    echo "Root partition is not on a LUKS encrypted drive."
    exit 1
fi
