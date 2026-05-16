#!/bin/bash
# Firewall configuration for K3s cluster networking
# Primarily tested on Fedora SecureBlue with firewalld

set -euo pipefail

if [ "$(id -u)" != 0 ]; then
	echo "Run as root." >&2
	exit 1
fi

# Check for firewalld
if ! command -v firewall-cmd >/dev/null 2>&1; then
	echo "Warning: firewall-cmd not found. Skipping firewall configuration."
	echo "If using a different firewall, ensure interfaces cni0 and flannel.1 are trusted."
	exit 0
fi

firewall-cmd --permanent --zone=trusted --add-interface=cni0
firewall-cmd --permanent --zone=trusted --add-interface=flannel.1 2>/dev/null || true
firewall-cmd --reload

echo "Firewall configured. Note: VPNs may interfere with cluster networking and should run on an upstream router."
